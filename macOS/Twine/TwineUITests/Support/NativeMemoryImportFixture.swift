import Foundation
import XCTest

/// Uses the installed Codex importer with disposable native homes, without credentials or model calls.
struct NativeMemoryImportFixture {
    let app: XCUIApplication
    let folder: URL
    let source: URL
    let destination: URL
    let config: URL
    let body = "# Trial customer\n\nUse Juniper Labs and demo-juniper-17 for this fictional project.\n"
}

extension TwineUITests {
    @MainActor
    func makeNativeMemoryFixture(hasMemories: Bool = true, enabled: Bool = true) throws -> NativeMemoryImportFixture {
        let root = try makeTestFolder(prefix: "TwineNativeMemoryUI").resolvingSymlinksInPath()
        let folder = root.appending(path: "project")
        let nativeHome = root.appending(path: "native-home")
        let codex = nativeHome.appending(path: ".codex")
        let key = folder.path.map { $0.isASCII && $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let source = nativeHome.appending(path: ".claude/projects/\(key)/memory")
        let destination = codex.appending(path: "memories/extensions/external_agent_import/resources/\(key)")
        for directory in [folder, codex, source] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let config = codex.appending(path: "config.toml")
        try "[features]\nmemories = \(enabled)\n".write(to: config, atomically: true, encoding: .utf8)
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["HOME"] = nativeHome.path
        app.launchEnvironment["CODEX_HOME"] = codex.path
        app.launchEnvironment["CODEX_SQLITE_HOME"] = codex.path
        app.launchEnvironment["CLAUDE_CONFIG_DIR"] = nativeHome.appending(path: ".claude").path
        app.launchEnvironment["SHELL"] = "/bin/bash"
        app.launchEnvironment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        if hasMemories {
            guard let binary = ProcessInfo.processInfo.environment["TWINE_NATIVE_CODEX_PATH"],
                FileManager.default.isExecutableFile(atPath: binary)
            else { throw XCTSkip("Set TWINE_NATIVE_CODEX_PATH to test the installed native Codex importer.") }
            let bin = root.appending(path: "bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                atPath: bin.appending(path: "codex").path, withDestinationPath: binary)
            app.launchEnvironment["PATH"] = "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin"
        }
        let fixture = NativeMemoryImportFixture(
            app: app, folder: folder, source: source, destination: destination, config: config)
        if hasMemories {
            try "# Project memories\n\n[Trial customer](customer.md)\n".write(
                to: source.appending(path: "MEMORY.md"), atomically: true, encoding: .utf8)
            try fixture.body.write(to: source.appending(path: "customer.md"), atomically: true, encoding: .utf8)
            let session: [String: Any] = [
                "type": "user", "cwd": folder.path, "timestamp": "2026-10-24T12:00:00Z",
                "message": ["content": "Synthetic native memory UI test"],
            ]
            var data = try JSONSerialization.data(withJSONObject: session)
            data.append(10)
            try data.write(to: source.deletingLastPathComponent().appending(path: "session.jsonl"))
        }
        return fixture
    }

    @MainActor
    func openNativeMemory(in app: XCUIApplication) {
        let entry = app.buttons["openNativeMemory"]
        if !entry.waitForExistence(timeout: 5) { sidebarToggle(in: app).click() }
        XCTAssertTrue(entry.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(entry.isHittable)
        entry.click()
        XCTAssertTrue(app.buttons["importClaudeMemories"].waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    func waitForNativeStatus(_ title: String, in app: XCUIApplication) {
        let status = app.staticTexts["nativeMemoryImportStatus"]
        let matches = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in status.exists && staticTextValue(status) == title }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 30), .completed, app.debugDescription)
    }
}
