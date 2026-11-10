import XCTest

extension HandshakeUITests {
    @MainActor
    func testAdversarialConnectionsAndExitedHarnessKeepInteractiveShells() throws {
        let app = try workflowRunApp()
        defer { app.terminate() }
        func item(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
        app.buttons["newWorkflow"].click()
        XCTAssertTrue(item("workflowChoice-Adversarial").waitForExistence(timeout: 10))
        item("workflowChoice-Adversarial").click()
        for role in ["implementer", "reviewer"] {
            let picker = item("roleHarness-\(role)-0")
            XCTAssertTrue(picker.waitForExistence(timeout: 10), app.debugDescription)
            let available = expectation(
                for: NSPredicate { _, _ in picker.value as? String == "pi" }, evaluatedWith: nil)
            wait(for: [available], timeout: 30)
        }
        app.buttons["workflowTab-1"].click()
        app.buttons["workflowTab-2"].click()
        app.typeText("x")
        // Draft activation is asynchronous, so give a stray key time to reach the shell.
        XCTAssertFalse(app.staticTexts["Draft"].waitForNonExistence(timeout: 2), "Typing stays out of the shell")
        XCTAssertTrue(item("workflowStart").exists)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(item("workflowAgentConnections").waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(item("workflowMarkDone").exists)
        XCTAssertTrue(item("workflowAgentConnections").isEnabled)
        XCTAssertTrue(app.buttons["agentSubtab-2"].exists)
        inspectStage("implement", in: app)
        checkAgentConnections(item("workflowAgentConnections"))
        // The system fixture exits without reporting a result: the same pane must return to a shell.
        let bin = try XCTUnwrap(app.launchEnvironment["HANDSHAKE_HARNESS_PATH"]?.split(separator: ":").first)
        let folder = URL(filePath: String(bin)).deletingLastPathComponent()
        let witness = folder.appending(path: "shell-still-usable")
        app.buttons["agentSubtab-1"].click()
        app.typeText("touch shell-still-usable\r")
        let shellWorked = expectation(
            for: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: witness.path)
            }, evaluatedWith: nil)
        wait(for: [shellWorked], timeout: 10)
        XCTAssertFalse(completedWorkflowTab(in: app).exists, "Process exit must not claim work completion")
        XCTAssertFalse(item("workflowForceStop").exists, "No native agents remain to stop")
        XCTAssertTrue(item("workflowAgentConnections").isEnabled)
        attachScreenshot(of: app, named: "Workflow controls and recovered interactive shell")

    }

    @MainActor
    private func checkAgentConnections(_ individual: XCUIElement) {
        XCTAssertTrue(individual.isEnabled)
        individual.click()
        let modeOn = expectation(
            for: NSPredicate { _, _ in individual.value as? String == "Disconnected" }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [modeOn], timeout: 5), .completed)
        individual.click()
        let modeOff = expectation(
            for: NSPredicate { _, _ in individual.value as? String == "Connected" }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [modeOff], timeout: 5), .completed)
    }

    @MainActor
    private func inspectStage(_ stage: String, in app: XCUIApplication) {
        func item(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
        XCTAssertTrue(item("inspectWorkflowType").waitForExistence(timeout: 10), app.debugDescription)
        item("inspectWorkflowType").click()
        XCTAssertTrue(item("workflowTypeInspector").waitForExistence(timeout: 5), app.debugDescription)
        let overview = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS %@",
                "Implementer to Reviewer: Work complete", "Reviewer to Implementer: Changes requested")
        ).firstMatch
        XCTAssertTrue(overview.exists, app.debugDescription)
        XCTAssertFalse(item("workflowStart").exists)
        XCTAssertFalse(item("roleHarness-implementer-0").exists)
        attachScreenshot(of: app, named: "Live graph at \(stage)")
        item("closeWorkflowType").click()
        XCTAssertTrue(item("workflowTypeInspector").waitForNonExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    func completedWorkflowTab(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND value CONTAINS %@", "workflowTab-", "Done")
        ).firstMatch
    }

    @MainActor
    func workflowRunApp(appearance: String? = nil) throws -> XCUIApplication {
        let folder = FileManager.default.temporaryDirectory.appending(path: "HandshakeRunUI-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let bin = folder.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        // A system binary avoids macOS's restriction on executing scripts written by the
        // sandboxed UI test runner. It exits without reporting a result, exercising shell recovery.
        try FileManager.default.createSymbolicLink(
            at: bin.appending(path: "pi"),
            withDestinationURL: URL(filePath: "/usr/bin/true"))
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["HANDSHAKE_TEST_PREFERENCES_SUITE"] =
            "com.twineproject.Twine.tests.TwineRunUITests-\(UUID())"
        app.launchEnvironment["HANDSHAKE_TEST_APPEARANCE"] = appearance
        app.launchEnvironment["HANDSHAKE_HARNESS_PATH"] = "\(folder.path)/bin:/bin:/usr/bin"
        app.launch()
        func item(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1000, height: 720))
        XCTAssertTrue(item("workflowChoice-Terminal").waitForExistence(timeout: 10))
        item("workflowChoice-Terminal").click()
        XCTAssertTrue(item("newTabChoices").waitForNonExistence(timeout: 10), app.debugDescription)
        return app
    }

    @MainActor
    func testCoordinatorGraphShowsWorkersAndHandoffs() throws {
        try checkCoordinatorGraph(appearance: "Light")
    }

    @MainActor
    func testCoordinatorGraphInDarkAppearance() throws {
        try checkCoordinatorGraph(appearance: "Dark")
    }

    @MainActor
    private func checkCoordinatorGraph(appearance: String) throws {
        let app = try workflowRunApp(appearance: appearance)
        defer { app.terminate() }
        func item(_ id: String) -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: id).firstMatch
        }
        app.buttons["newWorkflow"].click()
        XCTAssertTrue(item("workflowChoice-Coordinator").waitForExistence(timeout: 10))
        attachScreenshot(of: app, named: "Workflow choices in \(appearance)")
        item("workflowChoice-Coordinator").click()
        let overview = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Planner to Worker 1: Work complete")
        ).firstMatch
        XCTAssertTrue(overview.waitForExistence(timeout: 10))
        XCTAssertTrue(
            overview.label.contains("Planner to Worker 2: Work complete"), app.debugDescription)
        XCTAssertTrue(
            overview.label.contains("Worker 1 to Coordinator: Work complete"), app.debugDescription)
        XCTAssertTrue(
            overview.label.contains("Worker 2 to Coordinator: Work complete"), app.debugDescription)
        attachScreenshot(of: app, named: "Coordinator launch graph in \(appearance)")
    }

}
