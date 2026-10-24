import Foundation
import Testing

@testable import Twine

@MainActor
struct SharedMemoryTests {
    @Test func realBridgePersistsPolicyAndSharesInboxNotesOnlyWithinTheirFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "TwineSharedMemory-\(UUID())")
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
        let second = try await client.sharedMemory(folder: other.path, action: .init(operation: "refresh"))
        #expect(!second.enabled)
        #expect(second.notes.isEmpty)
        let id = try #require(snapshot.notes.first?.id)
        snapshot = try await client.sharedMemory(folder: folder.path, action: .init(operation: "withdraw", id: id))
        #expect(snapshot.notes.first?.status == "withdrawn")
        #expect(try !String(contentsOfFile: snapshot.catalogPath, encoding: .utf8).contains("Test procedure"))
        snapshot = try await client.sharedMemory(
            folder: folder.path, action: .init(operation: "setEnabled", enabled: false))
        #expect(!snapshot.enabled)
    }
}
