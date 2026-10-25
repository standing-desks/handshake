import Foundation
import Testing

@testable import Handshake

@MainActor
struct AppStartupTests {
    @Test func disposableProductionStartupMigratesBeforePresentationAndOpensSavedFolder() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let launch = AppPaths.launch(environment: [:], isDebug: false, applicationSupport: root)
        let legacy = try #require(launch.legacyDirectory)
        let source = CoreWorker(dataDirectory: legacy)
        _ = try await source.open()
        _ = try await source.send(.openFolder(path: folder.path))
        await source.close()
        let savedLayout = WorkflowLayout(
            mode: .bento, focusedAgentID: 42, paneAgentIDs: [42, 43], columnFraction: 0.7,
            rowFractions: [0.3, 0.6])
        let layout = try JSONEncoder().encode([folder.path: ["7": savedLayout]])
        try layout.write(to: legacy.appending(path: "workflow-layouts.json"))
        #expect(!FileManager.default.fileExists(atPath: launch.dataDirectory.path))
        let startup = AppStartup()
        await startup.prepare(launch)
        guard case .ready(let presentation) = startup.state else {
            Issue.record("Production startup did not finish: \(startup.state)")
            return
        }
        #expect(try Data(contentsOf: launch.dataDirectory.appending(path: "workflow-layouts.json")) == layout)
        #expect(FileManager.default.fileExists(atPath: legacy.appending(path: "twine.db").path))
        #expect(FileManager.default.fileExists(atPath: launch.dataDirectory.appending(path: "handshake.db").path))
        await presentation.layouts.load()
        #expect(presentation.layouts.layout(for: 7, in: folder.path) == savedLayout)
        let reloaded = WorkflowLayouts(fileURL: launch.dataDirectory.appending(path: "workflow-layouts.json"))
        await reloaded.load()
        #expect(reloaded.layout(for: 7, in: folder.path) == savedLayout)
        let session = presentation.windows.session(id: UUID())
        session.coreClient.start()
        do {
            try await session.coreClient.waitUntilRunning()
            #expect(session.coreClient.snapshot?.folders.openFolder == folder.path)
        } catch {
            await session.coreClient.stop()
            throw error
        }
        await session.coreClient.stop()
    }

    @Test func failedMigrationNeverCreatesPresentationOrSwitchesDataRoot() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let launch = AppPaths.launch(environment: [:], isDebug: false, applicationSupport: root)
        let source = CoreWorker(dataDirectory: try #require(launch.legacyDirectory))
        _ = try await source.open()
        let startup = AppStartup()
        await startup.prepare(launch)
        if case .failed(let message) = startup.state {
            #expect(message.contains("in use"))
        } else {
            Issue.record("Migration failure was not surfaced")
        }
        #expect(!FileManager.default.fileExists(atPath: launch.dataDirectory.path))
        await source.close()
    }

    @Test func explicitDebugPreviewAndTestLaunchesCannotSelectProductionMigration() {
        let explicit = AppPaths.launch(environment: ["HANDSHAKE_DATA_DIRECTORY": "/tmp/isolated"], isDebug: false)
        #expect(explicit.dataDirectory.path == "/tmp/isolated")
        #expect(explicit.legacyDirectory == nil)
        for launch in [
            AppPaths.launch(environment: [:], isDebug: true),
            AppPaths.launch(environment: [:], isDebug: false, isTesting: true),
            AppPaths.launch(environment: ["XCODE_RUNNING_FOR_PREVIEWS": "1"], isDebug: false),
            AppPaths.launch(environment: ["XCTestConfigurationFilePath": "fixture"], isDebug: false),
        ] {
            #expect(launch.legacyDirectory == nil)
            #expect(launch.dataDirectory.path.hasPrefix(DevelopmentPaths.checkoutDirectory.path))
        }
    }

    @Test func dataOverridesPreferHandshakeAndKeepLegacyLaunchesIsolated() {
        for isDebug in [true, false] {
            let legacy = AppPaths.launch(environment: ["TWINE_DATA_DIRECTORY": "/tmp/old"], isDebug: isDebug)
            #expect(legacy.dataDirectory.path == "/tmp/old")
            #expect(legacy.legacyDirectory == nil)
            let both = AppPaths.launch(
                environment: ["HANDSHAKE_DATA_DIRECTORY": "/tmp/new", "TWINE_DATA_DIRECTORY": "/tmp/old"],
                isDebug: isDebug)
            #expect(both.dataDirectory.path == "/tmp/new")
            #expect(both.legacyDirectory == nil)
        }
    }

    @Test func isolatedBootstrapDoesNotTouchALegacySourceOrCreateDirectories() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let isolated = root.appending(path: "isolated")
        let prepared = try await CoreClient.prepareDataDirectory(.init(dataDirectory: isolated, legacyDirectory: nil))
        #expect(prepared == isolated)
        #expect(!FileManager.default.fileExists(atPath: isolated.path))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "HandshakeStartup-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
