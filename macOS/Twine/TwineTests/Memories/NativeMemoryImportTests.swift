import Foundation
import Testing

@testable import Twine

@MainActor
struct NativeMemoryImportTests {
    @Test func checkingStatusDoesNotImportAndExplicitImportPreservesPendingConsolidation() async {
        let transport = DeferredMemoryTransport()
        let client = CoreClient(transport: transport)
        let model = NativeMemoryImportModel()
        await transport.setNativeImportResult(.success(snapshot(status: "ready", canImport: true)))
        await model.refresh(client: client, folder: "/folder")
        let checked = await transport.receivedNativeImportRequests()
        #expect(checked.map(\.action) == [.status])
        #expect(checked.map(\.folder) == ["/folder"])
        #expect(model.canImport)
        #expect(model.snapshot?.sourceCount == 3)

        let message = "The native import completed. Codex consolidation is still pending."
        await transport.setNativeImportResult(
            .success(snapshot(status: "imported", canImport: false, message: message)))
        await model.importMemories(client: client, folder: "/folder")
        let imported = await transport.receivedNativeImportRequests()
        #expect(imported.map(\.action) == [.status, .importMemories])
        #expect(model.statusTitle == "Submitted to Codex")
        #expect(model.snapshot?.message == message)
        #expect(!model.canImport)
        #expect(!model.isWorking)
    }

    @Test func unavailableSourceCannotSubmitAnImport() async {
        let transport = DeferredMemoryTransport()
        let client = CoreClient(transport: transport)
        let model = NativeMemoryImportModel()
        await model.importMemories(client: client, folder: "/folder")
        #expect(await transport.receivedNativeImportRequests().isEmpty)
        await transport.setNativeImportResult(.success(snapshot(status: "unavailable", canImport: false)))
        await model.refresh(client: client, folder: "/folder")
        await model.importMemories(client: client, folder: "/folder")
        let requests = await transport.receivedNativeImportRequests()
        #expect(requests.map(\.action) == [.status])
        #expect(model.statusTitle == "Import unavailable")
    }

    @Test func failedStatusDisablesStaleImportUntilARefreshSucceeds() async {
        let transport = DeferredMemoryTransport()
        let client = CoreClient(transport: transport)
        let model = NativeMemoryImportModel()
        await transport.setNativeImportResult(.success(snapshot(status: "ready", canImport: true)))
        await model.refresh(client: client, folder: "/folder")
        await transport.setNativeImportResult(.failure(.failed("Native memory directory changed.")))
        await model.refresh(client: client, folder: "/folder")
        #expect(model.snapshot?.claudePath == "/native/claude/memory")
        #expect(model.failure?.contains("Native memory directory changed.") == true)
        #expect(!model.canImport)
        await model.importMemories(client: client, folder: "/folder")
        let requests = await transport.receivedNativeImportRequests()
        #expect(requests.map(\.action) == [.status, .status])
        await transport.setNativeImportResult(.success(snapshot(status: "ready", canImport: true)))
        await model.refresh(client: client, folder: "/folder")
        #expect(model.failure == nil)
        #expect(model.canImport)
    }

    @Test func reopeningWhileACancelledStatusRequestFinishesStillLoadsStatus() async throws {
        let transport = DeferredMemoryTransport()
        let client = CoreClient(transport: transport)
        let model = NativeMemoryImportModel()
        await transport.deferNativeImports()
        let original = Task { await model.refresh(client: client, folder: "/folder") }
        try await transport.waitForNativeImports(1)
        original.cancel()
        var reopenedStarted = false
        let reopened = Task {
            reopenedStarted = true
            await model.refresh(client: client, folder: "/folder")
        }
        while !reopenedStarted { await Task.yield() }
        await transport.completeNativeImport(0, result: .success(snapshot(status: "ready", canImport: true)))
        await original.value
        try await transport.waitForNativeImports(2)
        #expect(model.snapshot == nil)
        let message = "No import is pending; native consolidation has not been verified."
        await transport.completeNativeImport(
            1, result: .success(snapshot(status: "current", canImport: false, message: message)))
        await reopened.value
        #expect(model.snapshot?.message == message)
        #expect(model.statusTitle == "No pending import")
        #expect(!model.isWorking)
        #expect(model.failure == nil)
        let requests = await transport.receivedNativeImportRequests()
        #expect(requests.map(\.action) == [.status, .status])
    }

    private func snapshot(
        status: String, canImport: Bool, message: String = "Native memory status."
    ) -> NativeMemoryImportSnapshot {
        .init(
            folder: "/folder", claudePath: "/native/claude/memory", codexPath: "/native/codex/memories",
            sourceCount: 3, canImport: canImport, status: status, message: message, importID: nil)
    }
}
