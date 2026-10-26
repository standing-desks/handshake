import Foundation
import Testing

@testable import Handshake

@MainActor
struct FeatureFlagsTests {
    @Test func settingAppliesTheSavedFileAndPreservesVersionProtection() async throws {
        let transport = FeatureFlagTestTransport()
        let client = CoreClient(transport: transport)
        let model = FeatureFlagsModel()
        await model.load(client: client)
        #expect(model.snapshot?.flags.first?.enabled == false)
        var applied: FilePreview?
        await model.set(.crossAgentMemoryConsolidation, enabled: true, client: client) { applied = $0 }
        #expect(applied?.text?.contains("true") == true)
        #expect(model.snapshot?.flags.first?.enabled == true)
        #expect(await transport.lastExpectedVersion?.fingerprint == "one")
        #expect(!model.needsApply && !model.isSaving && model.failure == nil)
    }

    @Test func conflictRefreshesCurrentValuesWithoutApplyingTheRejectedChange() async {
        let transport = FeatureFlagTestTransport(conflicts: true)
        let client = CoreClient(transport: transport)
        let model = FeatureFlagsModel()
        await model.load(client: client)
        var applied = false
        await model.set(.crossAgentMemoryConsolidation, enabled: true, client: client) { _ in applied = true }
        #expect(!applied)
        #expect(model.failure?.contains("changed elsewhere") == true)
        #expect(model.snapshot?.file.version?.fingerprint == "two")
        #expect(model.snapshot?.flags.first?.enabled == false)
    }

    @Test func failedApplyStaysRetryableAcrossReopenAndRetryRefreshesTheFile() async {
        let transport = FeatureFlagTestTransport()
        let client = CoreClient(transport: transport)
        let model = FeatureFlagsModel()
        await model.load(client: client)
        await model.set(.crossAgentMemoryConsolidation, enabled: true, client: client) { _ in
            throw CoreFailure.failed("Folder was unavailable")
        }
        #expect(model.needsApply)
        #expect(model.snapshot?.file.text?.contains("true") == true)
        #expect(model.snapshot?.file.version?.fingerprint == "two")
        await model.load(client: client)
        #expect(model.needsApply && model.failure?.contains("Apply Again") == true)
        var applied: FilePreview?
        await model.applyAgain(client: client) { applied = $0 }
        #expect(applied?.text?.contains("true") == true)
        #expect(!model.needsApply && model.failure == nil)
        #expect(model.snapshot?.flags.first?.enabled == true)
        #expect(await transport.saves == 1)
    }

    @Test func readFailureAfterDurableSaveDoesNotSkipApplication() async {
        let transport = FeatureFlagTestTransport(failReadAfterSave: true)
        let client = CoreClient(transport: transport)
        let model = FeatureFlagsModel()
        await model.load(client: client)
        var applied = false
        await model.set(.crossAgentMemoryConsolidation, enabled: true, client: client) { _ in applied = true }
        #expect(applied && !model.needsApply)
        #expect(model.snapshot?.file.text?.contains("true") == true)
        #expect(model.snapshot?.file.version?.fingerprint == "two")
        #expect(model.failure != nil)
        await transport.allowReads()
        await model.load(client: client)
        #expect(model.snapshot?.flags.first?.enabled == true)
        #expect(model.failure == nil)
    }

    @Test func loadingDuringAnApplyDoesNotLeaveAStaleRetryWarning() async {
        let client = CoreClient(transport: FeatureFlagTestTransport())
        let model = FeatureFlagsModel()
        await model.load(client: client)
        var resume: CheckedContinuation<Void, Never>?
        let setting = Task {
            await model.set(.crossAgentMemoryConsolidation, enabled: true, client: client) { _ in
                await withCheckedContinuation { resume = $0 }
            }
        }
        while resume == nil { await Task.yield() }
        await model.load(client: client)
        resume?.resume()
        await setting.value
        #expect(!model.needsApply && model.failure == nil)
        #expect(model.snapshot?.flags.first?.enabled == true)
    }

    @Test func readStartedBeforeASaveCannotReplaceTheSavedReceipt() async {
        let transport = FeatureFlagTestTransport()
        let client = CoreClient(transport: transport)
        let model = FeatureFlagsModel()
        await model.load(client: client)
        await transport.deferNextRead()
        let oldRead = Task { await model.load(client: client) }
        while !(await transport.hasDeferredRead()) { await Task.yield() }
        await model.set(.crossAgentMemoryConsolidation, enabled: true, client: client) { _ in }
        await transport.finishDeferredRead()
        await oldRead.value
        #expect(model.snapshot?.flags.first?.enabled == true)
        #expect(model.snapshot?.file.version?.fingerprint == "two")
        #expect(model.failure == nil)
    }

    @Test func rawConfigurationSaveRefreshesTheFlagSnapshot() async {
        let transport = FeatureFlagTestTransport()
        let client = CoreClient(transport: transport)
        let model = FeatureFlagsModel()
        await model.load(client: client)
        await transport.externalChange(true)
        await model.configurationApplied(client: client)
        #expect(model.snapshot?.flags.first?.enabled == true)
    }
}

private actor FeatureFlagTestTransport: CoreTransport {
    private var enabled = false
    private var shouldDeferRead = false
    private var deferredRead: CheckedContinuation<FeatureFlagSnapshot, Never>?
    private var deferredSnapshot: FeatureFlagSnapshot?
    private var version = "one"
    private let conflicts: Bool
    private var failReadAfterSave: Bool
    private(set) var lastExpectedVersion: FileVersion?
    private(set) var saves = 0

    init(conflicts: Bool = false, failReadAfterSave: Bool = false) {
        self.conflicts = conflicts
        self.failReadAfterSave = failReadAfterSave
    }

    func allowReads() { failReadAfterSave = false }
    func externalChange(_ value: Bool) {
        enabled = value
        version = "external"
    }
    func deferNextRead() { shouldDeferRead = true }
    func hasDeferredRead() -> Bool { deferredRead != nil }
    func finishDeferredRead() {
        if let deferredSnapshot { deferredRead?.resume(returning: deferredSnapshot) }
        deferredRead = nil
        deferredSnapshot = nil
    }
    func featureFlags() async throws -> FeatureFlagSnapshot {
        if saves > 0 && failReadAfterSave { throw CoreFailure.failed("Read unavailable") }
        let current = FeatureFlagSnapshot(
            flags: [
                FeatureFlagState(
                    id: .crossAgentMemoryConsolidation, title: "Cross-agent memory consolidation",
                    description: "Share project memories.", enabled: enabled)
            ], file: file())
        if shouldDeferRead {
            shouldDeferRead = false
            deferredSnapshot = current
            return await withCheckedContinuation { deferredRead = $0 }
        }
        return current

    }
    func setFeatureFlag(_ id: FeatureFlagID, enabled: Bool, expectedVersion: FileVersion) -> FileSaveResult {
        lastExpectedVersion = expectedVersion
        saves += 1
        version = "two"
        if !conflicts { self.enabled = enabled }
        return FileSaveResult(status: conflicts ? .conflict : .saved, file: file(), message: nil)
    }
    private func file() -> FilePreview {
        FilePreview(
            path: "/config/handshake/config.toml", status: .text,
            text: "[feature_flags]\ncross_agent_memory_consolidation = \(enabled)\n", message: nil,
            version: FileVersion(fingerprint: version, utf8BOM: false))
    }
    func open() -> CoreSnapshot { .testReady() }
    func close() {}
    func snapshot() -> CoreSnapshot { .testReady() }
    func send(_ command: CoreCommand) throws -> CoreCommandReceipt { throw CoreFailure.unexpectedCommandResult }
    func pollFiles(_ request: FileBrowserRequest) -> FileBrowserSnapshot? { nil }
    func saveFile(_ request: FileSaveRequest) throws -> FileSaveResult { throw CoreFailure.unexpectedCommandResult }
    func events(after sequence: UInt64, limit: UInt32) -> [CoreEvent] { [] }
    func nextTerminalChunk() -> CoreTerminalChunk? { nil }
    func writeTerminalInput(terminalID: UInt64, bytes: Data) {}
    func resizeTerminal(terminalID: UInt64, size: CoreTerminalSize) {}
}
