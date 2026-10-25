import Foundation
import XCTest

/// Two tiny native homes; these UX tests never authenticate or call a model.
struct TwineMemoryFixture {
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

extension TwineUITests {
    @MainActor
    func makeTwineMemoryFixture(hasMemories: Bool = true) throws -> TwineMemoryFixture {
        let root = try makeTestFolder(prefix: "TwineAMISMemoryUI").resolvingSymlinksInPath()
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
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["HOME"] = home.path
        app.launchEnvironment["CODEX_HOME"] = codex.path
        app.launchEnvironment["CLAUDE_CONFIG_DIR"] = home.appending(path: ".claude").path
        app.launchEnvironment["TWINE_MEMORY_DIRECTORY"] = store.path
        app.launchEnvironment["SHELL"] = "/bin/bash"
        app.launchEnvironment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return TwineMemoryFixture(app: app, folder: folder, source: source, store: store)
    }

    @MainActor
    func openTwineMemory(in app: XCUIApplication) {
        let entry = app.buttons["openNativeMemory"]
        if !entry.waitForExistence(timeout: 5) { sidebarToggle(in: app).click() }
        XCTAssertTrue(entry.waitForExistence(timeout: 10), app.debugDescription)
        entry.click()
        XCTAssertTrue(app.buttons["twineMemorySync"].waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor
    func waitForTwineText(_ value: String, identifier: String, in app: XCUIApplication) {
        let element = app.staticTexts[identifier]
        let matches = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in element.exists && staticTextValue(element) == value }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 30), .completed, app.debugDescription)
    }
}
