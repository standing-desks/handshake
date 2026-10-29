import XCTest

extension HandshakeUITests {
    @MainActor
    func testShellAgentPresentationPreservesShellAndReturnsAfterExit() throws {
        let folder = try makeTestFolder(prefix: "HandshakeShellAgent")
        // Deterministic foreground programs exercise real shell integration without account access.
        try """
        printf 'Agent fixture ready\\n'
        while IFS= read -r line; do
            [ "$line" = exit ] && exit 0
            printf '%s\\n' "$line" >> agent-input
        done
        """.write(to: folder.appending(path: "agent-stub.txt"), atomically: true, encoding: .utf8)
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["SHELL"] = "/bin/zsh"
        app.launchEnvironment["ZDOTDIR"] = folder.path
        app.launch()
        defer { app.terminate() }
        let tab = app.buttons["workflowTab-1"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["workflowChoice-Terminal"].click()
        // Create executable scripts from the app's shell, outside the test runner's execution restrictions.
        app.typeText("printf '#!/bin/sh\\n' > codex; cat agent-stub.txt >> codex; chmod +x codex; cp codex claude\r")
        app.typeText("HANDSHAKE_PROBE=preserved; echo $$ > before-pid\r")
        let before = try writtenProcessID(in: folder.appending(path: "before-pid"), app: app)

        for (binary, title) in [("codex", "Codex"), ("claude", "Claude Code")] {
            app.typeText("./\(binary)\r")
            let agent = expectation(for: NSPredicate(format: "label == %@", title), evaluatedWith: tab)
            XCTAssertEqual(XCTWaiter.wait(for: [agent], timeout: 10), .completed, app.debugDescription)
            app.typeText("input-\(binary)\r")
            waitForFile(folder.appending(path: "agent-input"), containing: "input-\(binary)", in: app)
            app.buttons["tracesHeader"].click()
            let step = app.buttons.matching(
                NSPredicate(
                    format: "identifier BEGINSWITH 'traceSpan-' AND label CONTAINS %@", "\(title): ./\(binary)"
                )
            ).firstMatch
            XCTAssertTrue(step.waitForExistence(timeout: 10), app.debugDescription)
            attachWindow(in: app, name: "Solid running trace dot and \(title) shell presentation")
            app.buttons["tracesHeader"].click()
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.4)).click()
            app.typeText("exit\r")
            let terminal = expectation(for: NSPredicate(format: "label == 'Terminal'"), evaluatedWith: tab)
            XCTAssertEqual(XCTWaiter.wait(for: [terminal], timeout: 10), .completed, app.debugDescription)
        }

        app.typeText("echo $$ > after-pid; echo $HANDSHAKE_PROBE > shell-value\r")
        XCTAssertEqual(try writtenProcessID(in: folder.appending(path: "after-pid"), app: app), before)
        waitForFile(folder.appending(path: "shell-value"), containing: "preserved", in: app)
        app.terminate()
        app.launch()
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        XCTAssertEqual(tab.label, "Terminal", "Restoration starts a shell, not the last detected agent")
    }
}
