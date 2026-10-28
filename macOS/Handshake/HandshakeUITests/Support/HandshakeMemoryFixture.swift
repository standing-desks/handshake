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
        app.launchEnvironment["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "0"
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

extension HandshakeUITests {
    func writeMemoryPromptAgent(in folder: URL) throws -> URL {
        let bin = folder.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try """
        #!/usr/bin/python3
        import json, os, pathlib, subprocess, sys
        if '--help' in sys.argv:
            sys.stdout.write('--model <model> Model (e.g. "sonnet" or "opus")\\n')
            sys.exit(0)
        settings = json.loads(sys.argv[sys.argv.index('--settings') + 1])
        memory = settings['autoMemoryDirectory']
        hooks = settings['hooks']['UserPromptSubmit']
        command = next(h['command'] for g in hooks for h in g['hooks'] if not h.get('async', False))
        for group in settings['hooks']['SessionStart']:
            for hook in group['hooks']:
                subprocess.run(hook['command'], shell=True, input=json.dumps({
                    'hook_event_name':'SessionStart','session_id':'ui-session'
                }), text=True, capture_output=True, check=True)
        pathlib.Path('agent-launch.json').write_text(json.dumps({'arguments':sys.argv, 'memory_directory':memory}))
        pathlib.Path('agent-pid').write_text(str(os.getpid()))
        for line in sys.stdin:
            payload = json.dumps({'hook_event_name':'UserPromptSubmit','session_id':'ui-session','prompt':line})
            result = subprocess.run(command, shell=True, input=payload, text=True, capture_output=True)
            pathlib.Path('prompt-memory-response.json').write_text(result.stdout)
            sys.stdout.write('Prompt refreshed\\n')
            sys.stdout.flush()
        """.write(to: folder.appending(path: "memory-prompt-agent.py"), atomically: true, encoding: .utf8)
        return bin
    }

}

extension HandshakeUITests {
    @MainActor
    func revealHandshakeDetail(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), app.debugDescription)
        let viewport = app.scrollViews["handshakeMemoryViewport"]
        // Long lists need more scroll steps in small windows and with different native scroll-wheel settings.
        for _ in 0..<24 {
            let visible = viewport.frame.intersection(element.frame)
            let needsHitTarget = element.elementType == .button || element.elementType == .disclosureTriangle
            let fullyVisible = visible.height >= min(element.frame.height, viewport.frame.height) - 2
            let canActivate = !needsHitTarget || element.isHittable
            if fullyVisible && canActivate { return }
            let delta = min(90, max(-90, (viewport.frame.midY - element.frame.midY) / 2))
            viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).scroll(byDeltaX: 0, deltaY: delta)
        }
        XCTAssertGreaterThanOrEqual(
            viewport.frame.intersection(element.frame).height,
            min(element.frame.height, viewport.frame.height) - 2, app.debugDescription)
        if element.elementType == .button { XCTAssertTrue(element.isHittable, app.debugDescription) }
    }

}
