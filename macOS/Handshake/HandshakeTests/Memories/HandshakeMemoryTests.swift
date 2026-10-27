import Foundation
import Testing

@testable import Handshake

@MainActor
struct HandshakeMemoryTests {
    @Test func statusAndActionsDoNotOverlap() async throws {
        let transport = DeferredMemoryTransport()
        await transport.deferHandshakeRequests()
        let client = CoreClient(transport: transport)
        let model = HandshakeMemoryModel()
        let watching = Task { await model.watch(client: client, folder: "/project") }
        try await transport.waitForHandshakeActions(1)
        #expect(model.isUpdating)
        await model.perform(client: client, folder: "/project", action: .setEnabled(false))
        #expect(await transport.receivedHandshakeActions() == [.status])
        watching.cancel()
        await transport.completeHandshake(0, result: .success(snapshot()))
        await watching.value
        #expect(model.snapshot == nil)
        #expect(!model.isUpdating)
    }

    @Test func pollingPreservesAnActionFailureUntilRetry() async throws {
        let transport = DeferredMemoryTransport()
        await transport.setHandshakeResult(.success(snapshot()))
        let client = CoreClient(transport: transport)
        let model = HandshakeMemoryModel()
        let watching = Task { await model.watch(client: client, folder: "/project") }
        try await transport.waitForHandshakeActions(1)
        while model.isUpdating { await Task.yield() }
        await transport.setHandshakeResult(.failure(.failed("Policy could not be saved.")))
        await model.perform(client: client, folder: "/project", action: .setEnabled(false))
        #expect(model.failure?.contains("Policy could not be saved.") == true)
        await transport.setHandshakeResult(.success(snapshot()))
        try await transport.waitForHandshakeActions(3)
        while model.isUpdating { await Task.yield() }
        #expect(model.failure?.contains("Policy could not be saved.") == true)
        await model.perform(client: client, folder: "/project", action: .sync)
        #expect(model.failure == nil)
        watching.cancel()
        await watching.value
    }

    private func snapshot() -> HandshakeMemorySnapshot {
        .init(
            enabled: true, folder: "/project", storePath: "/twine/memories", amisPath: "/library.amis.json",
            claudePath: "/claude/memory", codexPath: "/codex", records: [], status: "sharing",
            message: "Native bytes delivered.", lastSync: nil, modelCalls: 0)
    }

    @Test func archiveDetailSurvivesPollingAndClearsAfterRestore() async throws {
        let transport = DeferredMemoryTransport()
        let client = CoreClient(transport: transport)
        let model = HandshakeMemoryModel()
        var archived = snapshot()
        archived.archivedRecords = [.init(id: "archive", title: "Checkout", sources: 1, preview: "Short preview")]
        archived.archiveDetail = .init(id: "archive", title: "Checkout", text: "Full retained checkout memory")
        await transport.setHandshakeResult(.success(archived))
        await model.perform(client: client, folder: "/project", action: .readArchive("archive"))
        #expect(model.archiveDetail?.text == "Full retained checkout memory")
        archived.archiveDetail = nil
        await transport.setHandshakeResult(.success(archived))
        await model.perform(client: client, folder: "/project", action: .status)
        #expect(model.archiveDetail?.text == "Full retained checkout memory")
        await transport.setHandshakeResult(.success(snapshot()))
        await model.perform(client: client, folder: "/project", action: .restore("archive"))
        #expect(model.archiveDetail == nil)
        #expect(await transport.receivedHandshakeActions() == [.readArchive("archive"), .status, .restore("archive")])
    }
}
