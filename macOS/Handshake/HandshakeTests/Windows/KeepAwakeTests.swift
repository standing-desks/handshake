import Foundation
import Testing

@testable import Handshake

@MainActor
struct KeepAwakeTests {
    @Test func quittingWaitsForAnInFlightEnableBeforeDisabling() async throws {
        let transport = KeepAwakeTestTransport()
        let model = KeepAwakeModel(client: CoreClient(transport: transport))
        let enable = Task { await model.update(true) }
        try await waitUntil { await transport.hasPendingEnable }
        let release = Task {
            try await Task.sleep(for: .milliseconds(50))
            await transport.finishEnable()
        }
        await model.stop()
        await enable.value
        try await release.value
        #expect(!model.isEnabled)
        #expect(await !transport.enabled)
        #expect(await transport.changes == [true, false])
        await model.update(true)
        #expect(await transport.changes == [true, false], "Shutdown must reject new enable requests")
    }

    @Test func anExplicitChangeWaitsForAnInFlightStatusPoll() async throws {
        let transport = KeepAwakeTestTransport()
        await transport.holdPoll()
        let model = KeepAwakeModel(client: CoreClient(transport: transport))
        let poll = Task { await model.update(nil) }
        try await waitUntil { await transport.hasPendingPoll }
        #expect(!model.isUpdating, "A status poll must leave the menu and toolbar available")
        var requested = false
        let enable = Task {
            requested = true
            await model.update(true)
        }
        try await waitUntil { requested }
        #expect(model.isUpdating, "An explicit change stays busy while it waits behind the poll")
        await transport.finishPoll()
        await poll.value
        try await waitUntil { await transport.hasPendingEnable }
        #expect(await transport.changes == [true])
        await transport.finishEnable()
        await enable.value
        #expect(model.isEnabled)
        #expect(!model.isUpdating)
        await model.stop()
    }

    @Test func aChildThatExitsDuringStartupShowsFailureAndStaysOff() async throws {
        let transport = KeepAwakeTestTransport()
        await transport.failLaunch()
        let model = KeepAwakeModel(client: CoreClient(transport: transport))
        await model.update(true)
        #expect(!model.isEnabled)
        #expect(model.failure != nil)
        #expect(!model.isUpdating)
    }

    @Test func aSuccessfulRetryClearsAFailureThatHasNoWindowToPresentIt() async throws {
        let transport = KeepAwakeTestTransport()
        let model = KeepAwakeModel(client: CoreClient(transport: transport))
        let enable = Task { await model.update(true) }
        try await waitUntil { await transport.hasPendingEnable }
        await transport.finishEnable()
        await enable.value
        await transport.stopChild()
        await model.update(nil)
        #expect(!model.isEnabled)
        #expect(model.failure != nil)
        await model.update(nil)
        #expect(model.failure != nil, "Polling preserves a failure until it can be presented or resolved")
        let retry = Task { await model.update(true) }
        try await waitUntil { await transport.hasPendingEnable }
        await transport.finishEnable()
        await retry.value
        #expect(model.isEnabled)
        #expect(model.failure == nil, "Opening a window after a successful menu retry must not show an obsolete error")
        await model.stop()
    }
}

private actor KeepAwakeTestTransport {
    private(set) var enabled = false
    private(set) var changes: [Bool] = []
    private var launchFails = false
    private var pending: CheckedContinuation<Void, Never>?
    private var pendingPoll: CheckedContinuation<Void, Never>?
    private var blocksPoll = false
    var hasPendingPoll: Bool { pendingPoll != nil }
    func holdPoll() { blocksPoll = true }
    func finishPoll() {
        blocksPoll = false
        pendingPoll?.resume()
        pendingPoll = nil
    }
    var hasPendingEnable: Bool { pending != nil }
    func failLaunch() { launchFails = true }
    func stopChild() { enabled = false }
    func finishEnable() {
        pending?.resume()
        pending = nil
    }
    func keepAwake(_ value: Bool?) async -> Bool {
        if value == nil, blocksPoll { await withCheckedContinuation { pendingPoll = $0 } }
        if let value {
            changes.append(value)
            if value && !launchFails { await withCheckedContinuation { pending = $0 } }
            enabled = value && !launchFails
        }
        return enabled
    }

    func open() throws -> CoreSnapshot { throw CoreFailure.unexpectedCommandResult }
    func close() {}
    func send(_ command: CoreCommand) throws -> CoreCommandReceipt { throw CoreFailure.unexpectedCommandResult }
    func snapshot() throws -> CoreSnapshot { throw CoreFailure.unexpectedCommandResult }
    func pollFiles(_ request: FileBrowserRequest) throws -> FileBrowserSnapshot? {
        throw CoreFailure.unexpectedCommandResult
    }
    func saveFile(_ request: FileSaveRequest) throws -> FileSaveResult { throw CoreFailure.unexpectedCommandResult }
    func events(after sequence: UInt64, limit: UInt32) -> [CoreEvent] { [] }
    func nextTerminalChunk() -> CoreTerminalChunk? { nil }
    func writeTerminalInput(terminalID: UInt64, bytes: Data) throws { throw CoreFailure.unexpectedCommandResult }
    func resizeTerminal(terminalID: UInt64, size: CoreTerminalSize) throws { throw CoreFailure.unexpectedCommandResult }
}

extension KeepAwakeTestTransport: CoreTransport {}
