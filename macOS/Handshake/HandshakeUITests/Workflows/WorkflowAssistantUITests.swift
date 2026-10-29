import XCTest

extension HandshakeUITests {
    @MainActor
    func testWorkflowAssistantCreatesAppliesUndoesAndSavesFromLeftPanel() throws {
        let (app, folder) = try workflowAssistantApp(enabled: true)
        let responseFile = folder.appending(path: "response.json")
        let validResponse = try Data(contentsOf: responseFile)
        try Data(#"{"message":"Invalid draft","toml":"bad"}"#.utf8).write(to: responseFile)
        app.launch()
        defer { app.terminate() }
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1200, height: 850))
        try openWorkflowAssistantDesigner(app, fixture: folder)
        let input = app.textViews["workflowAssistantInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertLessThan(input.frame.midX, app.windows.firstMatch.frame.midX)
        input.click()
        input.typeText("Route bugs and features to separate agents.")
        app.buttons["workflowAssistantSend"].click()
        let retry = app.buttons["workflowAssistantRetry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 20), app.debugDescription)
        try validResponse.write(to: responseFile)
        retry.click()
        let apply = app.buttons["workflowAssistantApply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(app.textFields["designerName"].value as? String, "")
        apply.click()
        let decision = app.buttons["graphNode-classify"]
        XCTAssertTrue(decision.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.textFields["designerName"].value as? String, "Triage draft")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(decision.waitForNonExistence(timeout: 5), app.debugDescription)
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(decision.waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["workflowAssistantHide"].click()
        XCTAssertFalse(input.exists)
        app.buttons["workflowAssistantShow"].click()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let ready = expectation(for: NSPredicate { _, _ in app.buttons["designerSave"].isEnabled }, evaluatedWith: nil)
        wait(for: [ready], timeout: 10)
        app.buttons["designerSave"].click()
        XCTAssertTrue(app.buttons["workflowEditType"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["workflowStart"].exists)
        attachScreenshot(of: app, named: "Generated workflow ready for a separate launch")
    }

    @MainActor
    func testWorkflowAssistantFlagAndStopKeepTheCurrentCanvas() throws {
        let (disabled, disabledFolder) = try workflowAssistantApp(enabled: false)
        disabled.launch()
        try openWorkflowAssistantDesigner(disabled, fixture: disabledFolder)
        XCTAssertFalse(disabled.textViews["workflowAssistantInput"].exists)
        disabled.terminate()

        let (app, folder) = try workflowAssistantApp(enabled: true, slow: true)
        app.launch()
        defer { app.terminate() }
        try openWorkflowAssistantDesigner(app, fixture: folder)
        let input = app.textViews["workflowAssistantInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.click()
        input.typeText("Create a workflow")
        app.buttons["workflowAssistantSend"].click()
        let stop = app.buttons["workflowAssistantStop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        stop.click()
        XCTAssertTrue(app.buttons["workflowAssistantSend"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["workflowAssistantApply"].exists)
        XCTAssertFalse(app.buttons["graphNode-classify"].exists)
    }

    @MainActor
    func testLiveWorkflowAssistantGeneratesThroughInstalledHarness() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let harnessPath = environment["HANDSHAKE_LIVE_WORKFLOW_HARNESS_PATH"] else {
            throw XCTSkip("Opt-in live workflow generation requires an installed authenticated harness.")
        }
        let (app, _) = try workflowAssistantApp(enabled: true)
        app.launchEnvironment["HANDSHAKE_HARNESS_PATH"] = harnessPath
        // The harness's normal authentication belongs to the local user, not the isolated app config.
        for key in ["CODEX_HOME", "CLAUDE_CONFIG_DIR"] {
            if let value = environment[key] { app.launchEnvironment[key] = value }
        }
        app.launch()
        defer { app.terminate() }
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1200, height: 850))
        try openWorkflowAssistantDesigner(app)
        let input = app.textViews["workflowAssistantInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 15), app.debugDescription)
        input.click()
        input.typeText(
            """
            Create a workflow named Live triage. Start with one Choice decision that routes bug to a Debugger
            and feature to an Implementer. Each selected agent returns the final result. Use default models.
            Generate the configuration now.
            """
        )
        app.buttons["workflowAssistantSend"].click()
        let apply = app.buttons["workflowAssistantApply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 180), app.debugDescription)
        apply.click()
        let ready = expectation(for: NSPredicate { _, _ in app.buttons["designerSave"].isEnabled }, evaluatedWith: nil)
        wait(for: [ready], timeout: 10)
        app.buttons["designerSave"].click()
        XCTAssertTrue(app.buttons["workflowStart"].waitForExistence(timeout: 10), app.debugDescription)
        attachScreenshot(of: app, named: "Live harness generated a valid workflow")
    }

    @MainActor
    private func openWorkflowAssistantDesigner(_ app: XCUIApplication, fixture: URL? = nil) throws {
        if let fixture {
            let terminal = app.buttons["workflowChoice-Terminal"]
            revealWorkflowChoice(terminal, in: app)
            terminal.click()
            XCTAssertTrue(app.scrollViews["newTabChoices"].waitForNonExistence(timeout: 5))
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            // macOS restricts executables created by the sandboxed UI runner. Install through the app's shell.
            app.typeText("cat author-stub.txt > bin/codex; chmod +x bin/codex\r")
            let installed = expectation(
                for: NSPredicate { _, _ in
                    FileManager.default.isExecutableFile(atPath: fixture.appending(path: "bin/codex").path)
                }, evaluatedWith: nil)
            wait(for: [installed], timeout: 10)
        }
        XCTAssertTrue(app.buttons["newWorkflow"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["newWorkflow"].click()
        let create = app.buttons["workflowCreateOwn"]
        revealWorkflowChoice(create, in: app)
        create.click()
        XCTAssertTrue(app.textFields["designerName"].waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor
    private func workflowAssistantApp(enabled: Bool, slow: Bool = false) throws -> (XCUIApplication, URL) {
        let folder = try makeTestFolder(prefix: "WorkflowAssistant")
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["SHELL"] = "/bin/sh"
        let root = URL(filePath: try XCTUnwrap(app.launchEnvironment["XDG_CONFIG_HOME"]))
            .appending(path: "handshake")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "[experimental]\nworkflow_assistant = \(enabled)\n".write(
            to: root.appending(path: "config.toml"), atomically: true, encoding: .utf8)
        let bin = folder.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let sourceRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sample = try String(
            contentsOf: sourceRoot.appending(path: "examples/workflows/decision-triage.toml"), encoding: .utf8
        )
        .replacingOccurrences(of: "Triage and assign", with: "Triage draft")
        let response = try JSONSerialization.data(withJSONObject: [
            "message": "A triage workflow is ready.", "toml": sample,
        ])
        try response.write(to: folder.appending(path: "response.json"))
        let script = """
            #!/bin/sh
            if [ "$1" = debug ]; then
              printf '%s\\n' '{"models":[{"slug":"sample-model","visibility":"list"}]}'
              exit 0
            fi
            response='\(folder.appending(path: "response.json").path)'
            while [ "$#" -gt 0 ]; do
              if [ "$1" = --output-last-message ]; then shift; output="$1"; fi
              shift
            done
            /bin/cat >/dev/null
            /bin/sleep \(slow ? "30" : "1")
            /bin/cat "$response" > "$output"
            """
        try script.write(to: folder.appending(path: "author-stub.txt"), atomically: true, encoding: .utf8)
        app.launchEnvironment["HANDSHAKE_HARNESS_PATH"] = "\(bin.path):/bin:/usr/bin"
        return (app, folder)
    }
}
