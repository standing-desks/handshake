import Foundation
import Testing

@testable import Handshake

@MainActor
struct SharedMemoryTests {
    @Test func refreshPreservesDetailFailureAndSearchClearsHiddenSelection() async {
        let transport = DeferredMemoryTransport()
        let snapshot = SharedMemorySnapshot(
            enabled: true, deliveryReady: true, folder: "/folder", inbox: "/inbox", catalogPath: "/catalog.md",
            notes: [
                .init(id: "first", title: "First note", source: "first.md", digest: "one", status: "shared"),
                .init(id: "second", title: "Second note", source: "second.md", digest: "two", status: "shared"),
            ], diagnostics: [], detail: nil)
        await transport.setSharedResult(snapshot, failRead: true)
        let client = CoreClient(transport: transport)
        let model = SharedMemoryModel()
        await model.perform(.init(operation: "refresh"), client: client, folder: "/folder")
        await model.loadSelected(client: client, folder: "/folder")
        #expect(model.selectedDetailError != nil)
        #expect(!model.isLoadingSelected)
        await model.perform(.init(operation: "refresh"), client: client, folder: "/folder")
        #expect(model.selectedText == nil)
        #expect(model.selectedDetailError != nil)
        #expect(!model.isLoadingSelected)
        model.query = "Second"
        #expect(model.selectedID == "second")
        #expect(model.selectedDetailError == nil)
        model.query = "no matches"
        #expect(model.selectedID == nil)
        #expect(model.selected == nil)
        #expect(model.selectedText == nil)
    }

    @Test func realBridgePersistsPolicyAndSharesInboxNotesOnlyWithinTheirFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "HandshakeSharedMemory-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "folder")
        let other = root.appending(path: "other")
        for path in [folder, other] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        let client = CoreClient(transport: CoreWorker(dataDirectory: root.appending(path: "data")))
        var snapshot = try await client.sharedMemory(folder: folder.path, action: .init(operation: "refresh"))
        #expect(!snapshot.enabled)
        snapshot = try await client.sharedMemory(
            folder: folder.path, action: .init(operation: "setEnabled", enabled: true))
        let note = URL(filePath: snapshot.inbox).appending(path: "from-agent.md")
        try "# Test procedure\nRun the targeted suite.".write(to: note, atomically: true, encoding: .utf8)
        snapshot = try await client.sharedMemory(folder: folder.path, action: .init(operation: "refresh"))
        #expect(snapshot.notes.count == 1)
        #expect(snapshot.notes.first?.status == "shared")
        #expect(snapshot.detail == nil)
        let second = try await client.sharedMemory(folder: other.path, action: .init(operation: "refresh"))
        #expect(!second.enabled)
        #expect(second.notes.isEmpty)
        let id = try #require(snapshot.notes.first?.id)
        snapshot = try await client.sharedMemory(folder: folder.path, action: .init(operation: "read", id: id))
        #expect(snapshot.detail?.id == id)
        #expect(snapshot.detail?.text == "# Test procedure\nRun the targeted suite.")
        snapshot = try await client.sharedMemory(folder: folder.path, action: .init(operation: "withdraw", id: id))
        #expect(snapshot.notes.first?.status == "withdrawn")
        #expect(try !String(contentsOfFile: snapshot.catalogPath, encoding: .utf8).contains("Test procedure"))
        snapshot = try await client.sharedMemory(
            folder: folder.path, action: .init(operation: "setEnabled", enabled: false))
        #expect(!snapshot.enabled)
    }

    @Test func largeLibraryRefreshesMetadataAndLoadsOnlyTheSelectedBody() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "HandshakeSharedMemoryScale-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let client = CoreClient(transport: CoreWorker(dataDirectory: root.appending(path: "data")))
        let initial = try await client.sharedMemory(
            folder: folder.path, action: .init(operation: "setEnabled", enabled: true))
        let largeText = "# Large procedure\n" + String(repeating: "Qualified memory content.\n", count: 2_000)
        let inbox = URL(filePath: initial.inbox)
        for index in 0..<260 {
            let text = index == 259 ? largeText : "# Procedure \(index)\nUnique procedure \(index)."
            try text.write(to: inbox.appending(path: "note-\(index).md"), atomically: true, encoding: .utf8)
        }
        let model = SharedMemoryModel()
        await model.perform(.init(operation: "refresh"), client: client, folder: folder.path)
        #expect(model.snapshot?.notes.count == 260)
        #expect(model.snapshot?.detail == nil)
        #expect(model.selectedText == nil)
        let large = try #require(model.snapshot?.notes.first { $0.title == "Large procedure" })
        model.selectedID = large.id
        await model.loadSelected(client: client, folder: folder.path)
        #expect(model.selectedText == largeText)
        await model.perform(.init(operation: "refresh"), client: client, folder: folder.path, background: true)
        #expect(model.snapshot?.detail == nil)
        #expect(model.selectedText == largeText)
        let other = try #require(model.snapshot?.notes.first { $0.id != large.id })
        model.selectedID = other.id
        #expect(model.selectedText == nil)
        await model.loadSelected(client: client, folder: folder.path)
        #expect(model.selectedText?.contains("Unique procedure") == true)
    }
}
