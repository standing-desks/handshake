import Foundation
import XCTest

/// Two tiny native homes; these UX tests never authenticate or call a model.
struct HandshakeMemoryFixture {
    let app: XCUIApplication
    let folder: URL
    let source: URL
    let store: URL

    func projectRoot() throws -> URL {
        let projects = store.appending(path: "projects")
        return try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil).first)
    }
}

extension HandshakeUITests {
    @MainActor
    func makeAMISFixture(hasMemories: Bool = true, featureEnabled: Bool = true) throws -> HandshakeMemoryFixture {
        let root = try makeTestFolder(prefix: "HandshakeAMISMemoryUI").resolvingSymlinksInPath()
        let folder = root.appending(path: "project")
        let home = root.appending(path: "native-home")
        let codex = home.appending(path: ".codex")
        let key = folder.path.map { $0.isASCII && $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let source = home.appending(path: ".claude/projects/\(key)/memory")
        let store = root.appending(path: "twine/memories")
        for directory in [folder, codex, source] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "[features]\nmemories = true\n".write(
            to: codex.appending(path: "config.toml"), atomically: true, encoding: .utf8)
        if hasMemories {
            try "# Demo account\n\nUse maple-417 for this fictional project.\n".write(
                to: source.appending(path: "demo.md"), atomically: true, encoding: .utf8)
        }
        let config = root.appending(path: "config/handshake/config.toml")
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings = """
            # Existing settings
            [terminal]
            font_size = 14 # keep this
            [feature_flags]
            cross_agent_memory_consolidation = \(featureEnabled)

            """
        try settings.write(to: config, atomically: true, encoding: .utf8)
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["HANDSHAKE_CONFIG_PATH"] = config.path
        app.launchEnvironment["HOME"] = home.path
        app.launchEnvironment["CODEX_HOME"] = codex.path
        app.launchEnvironment["CLAUDE_CONFIG_DIR"] = home.appending(path: ".claude").path
        app.launchEnvironment["HANDSHAKE_MEMORY_DIRECTORY"] = store.path
        app.launchEnvironment["SHELL"] = "/bin/bash"
        app.launchEnvironment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return HandshakeMemoryFixture(app: app, folder: folder, source: source, store: store)
    }

    @MainActor
    func openHandshakeMemory(in app: XCUIApplication) {
        let entry = app.buttons["openNativeMemory"]
        if !entry.waitForExistence(timeout: 5) { sidebarToggle(in: app).click() }
        XCTAssertTrue(entry.waitForExistence(timeout: 10), app.debugDescription)
        entry.click()
        XCTAssertTrue(app.buttons["handshakeMemorySync"].waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor
    func waitForHandshakeText(_ value: String, identifier: String, in app: XCUIApplication) {
        let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        let matches = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard element.exists else { return false }
                let text = element.elementType == .staticText ? staticTextValue(element) : element.label
                return text == value
            }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 30), .completed, app.debugDescription)
    }
}
