import XCTest

extension HandshakeUITests {
    @MainActor
    func testWorkflowTraceUsesPromptInsteadOfGraphAndSurvivesRelaunch() throws {
        let folder = try inspectorFolder()
        try writeInspectorAgent(in: folder)
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["SHELL"] = "/bin/sh"
        app.launchEnvironment["HANDSHAKE_HARNESS_PATH"] = "\(folder.path)/bin:/bin:/usr/bin"
        app.launchEnvironment["CLAUDE_CONFIG_DIR"] = folder.appending(path: "native").path
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 820, height: 573))
        app.buttons["workflowChoice-Terminal"].click()
        app.typeText(
            "mkdir bin; printf '#!/bin/sh\\n' > bin/claude; cat inspector-stub.txt >> bin/claude; chmod +x bin/claude\r"
        )
        waitForFile(folder.appending(path: "bin/claude"), containing: "inspector-events", in: app)
        app.buttons["newWorkflow"].click()
        app.buttons["workflowChoice-Adversarial"].click()
        for role in ["implementer", "reviewer"] {
            let picker = app.descendants(matching: .any).matching(identifier: "roleHarness-\(role)-0").firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout: 10))
            picker.click()
            app.menuItems["Claude Code"].click()
        }
        let start = app.buttons["workflowStart"]
        revealWorkflowChoice(start, in: app)
        start.click()
        XCTAssertTrue(start.waitForNonExistence(timeout: 10), app.debugDescription)
        waitForFile(folder.appending(path: "inspector-ready"), containing: "ready", in: app)
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1100, height: 850))
        app.buttons["tracesHeader"].click()
        let step = app.buttons.matching(
            NSPredicate(
                format:
                    "identifier BEGINSWITH 'traceSpan-' AND label CONTAINS 'Implementer: Inspect parallel coding work'"
            )
        ).firstMatch
        XCTAssertTrue(step.waitForExistence(timeout: 10), app.debugDescription)
        let id = step.identifier
        // All tool hooks have arrived; the prompt is still the assignment's visible title.
        XCTAssertFalse(step.label.contains("Graph"))
        attachWindow(in: app, name: "Workflow assignment uses the native prompt and a solid running dot")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["workflowTab-2"].waitForExistence(timeout: 10))
        app.buttons["workflowTab-2"].click()
        let savedStep = app.buttons[id]
        if !savedStep.exists { app.buttons["tracesHeader"].click() }
        XCTAssertTrue(savedStep.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(savedStep.label.contains("Inspect parallel coding work"))
    }
}
