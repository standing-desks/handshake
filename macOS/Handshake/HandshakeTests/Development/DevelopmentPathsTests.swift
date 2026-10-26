import Foundation
import Testing

@testable import Handshake

struct DevelopmentPathsTests {
    @Test(
        arguments: [
            "/tmp/checkouts/unrelated folder",
            "/tmp/Handshake/checkouts/Handshake",
            "/tmp/Twine/checkouts/Twine app",
        ],
        [
            "AppPaths.swift",
            "Development/AppPaths.swift",
            "Development/Previews/Nested/Example.swift",
            "Memories/MemoryExamples.swift",
        ])
    func sourceRelocationPreservesCheckout(checkoutPath: String, source: String) throws {
        let checkout = URL(filePath: checkoutPath, directoryHint: .isDirectory)
        let file = checkout.appending(path: "macOS/Handshake/Handshake/\(source)")
        let resolved = try #require(DevelopmentPaths.checkoutDirectory(containing: file.path))
        #expect(resolved == checkout)
    }

    @Test func unrelatedSourcePathsHaveNoCheckout() {
        #expect(DevelopmentPaths.checkoutDirectory(containing: "/tmp/Twine/Development/AppPaths.swift") == nil)
        #expect(DevelopmentPaths.checkoutDirectory(containing: "/tmp/macOS/Handshake/Other/AppPaths.swift") == nil)
    }

    @Test func buildCheckoutContainsRepositoryResources() {
        let checkout = DevelopmentPaths.checkoutDirectory
        #expect(FileManager.default.fileExists(atPath: checkout.appending(path: "Makefile").path))
        #expect(
            FileManager.default.fileExists(atPath: checkout.appending(path: "macOS/Handshake/Handshake.xcodeproj").path)
        )
    }

    @MainActor
    @Test func developmentConsumersKeepTheirPathsAndOverrides() {
        let checkout = DevelopmentPaths.checkoutDirectory
        #expect(AppPaths.previewDirectory.path == checkout.appending(path: "out/runtime/debug/previews").path)
        let environment = ProcessInfo.processInfo.environment
        let examples =
            environment["HANDSHAKE_MEMORY_EXAMPLE_ROOT"]
            ?? checkout.appending(path: "designs/memory-viewer-fixtures").path
        #expect(MemoryExamples.root == examples)
        if let override = environment["HANDSHAKE_DATA_DIRECTORY"] ?? environment["TWINE_DATA_DIRECTORY"] {
            #expect(AppPaths.dataDirectory == URL(filePath: override, directoryHint: .isDirectory))
        } else {
            // Test hosts stay isolated even when built in Release without an explicit override.
            #expect(AppPaths.dataDirectory.path == checkout.appending(path: "out/runtime/debug").path)
        }
    }
}
