import XCTest

extension HandshakeUITests {
    @MainActor
    func testSingleAgentUsesHarnessDefaultsAndRemembersYoloMode() throws {
        let folder = try makeTestFolder(prefix: "HandshakeSingleAgentLaunchUITests")
        try writeDefaultLaunchAgent(in: folder)
        let app = try makeApp(lastOpenFolder: folder)
        defer { app.terminate() }
        app.launchEnvironment["SHELL"] = "/bin/sh"
        app.launchEnvironment["HANDSHAKE_HARNESS_PATH"] = "\(folder.path)/bin:/bin:/usr/bin"
        app.launch()
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10), app.debugDescription)
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1000, height: 800))
        assertSingleAgentChoiceLayout(in: app)
        app.typeKey("=", modifierFlags: .command)
        assertSingleAgentChoiceLayout(in: app)
        app.typeKey("0", modifierFlags: .command)
        launchElement("workflowChoice-Terminal", in: app).click()
        app.typeText("mkdir bin; printf '#!/bin/sh\\n' > bin/claude; cat stub.txt >> bin/claude; chmod +x bin/claude\r")
        let installed = expectation(
            for: NSPredicate { _, _ in
                FileManager.default.isExecutableFile(atPath: folder.appending(path: "bin/claude").path)
            }, evaluatedWith: nil)
        wait(for: [installed], timeout: 10)
        app.buttons["newWorkflow"].click()
        let yolo = app.checkBoxes["singleAgentYolo"]
        XCTAssertTrue(yolo.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(String(describing: yolo.value ?? ""), "0")
        chooseHarness("claudeCode", displayName: "Claude Code", in: app)
        waitForFile(folder.appending(path: "agent-arguments"), containing: "--settings", in: app)
        try assertDefaultLaunchArguments(in: folder, skipsPrompts: false)
        app.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Cancelled"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["newWorkflow"].click()
        XCTAssertTrue(yolo.waitForExistence(timeout: 10), app.debugDescription)
        yolo.click()
        XCTAssertEqual(String(describing: yolo.value ?? ""), "1")
        XCTAssertFalse(app.menuItems["harness-claudeCode"].exists, "Toggling YOLO must not open the menu")
        chooseHarness("claudeCode", displayName: "Claude Code", in: app)
        waitForFile(folder.appending(path: "agent-arguments"), containing: "--dangerously-skip-permissions", in: app)
        try assertDefaultLaunchArguments(in: folder, skipsPrompts: true)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["newWorkflow"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["newWorkflow"].click()
        XCTAssertTrue(yolo.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(String(describing: yolo.value ?? ""), "1", "YOLO mode is remembered after relaunch")
        assertSingleAgentChoiceLayout(in: app)
        attachScreenshot(of: app, named: "Equal workflow boxes with YOLO mode inside Single agent")
    }

    @MainActor
    private func assertSingleAgentChoiceLayout(in app: XCUIApplication) {
        let singleAgent = launchElement("workflowChoice-Single agent", in: app)
        XCTAssertTrue(singleAgent.waitForExistence(timeout: 10), app.debugDescription)
        let checkbox = app.checkBoxes["singleAgentYolo"]
        XCTAssertTrue(checkbox.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(singleAgent.frame.contains(checkbox.frame), "YOLO mode stays inside the Single agent box")
        for name in ["Terminal", "Adversarial", "Coordinator"] {
            let tile = launchElement("workflowChoice-\(name)", in: app)
            XCTAssertTrue(tile.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertEqual(tile.frame.height, singleAgent.frame.height, accuracy: 1, "\(name) has the same height")
            // Scaled grid columns can round to neighboring pixels.
            XCTAssertEqual(tile.frame.width, singleAgent.frame.width, accuracy: 2, "\(name) has the same width")
        }
    }

    private func writeDefaultLaunchAgent(in folder: URL) throws {
        try """
        case "$1" in
            --help)
                printf '%s\\n' '--model <model>  Model (e.g. "sonnet" or "opus")' '--effort <level> (low, high)'
                exit 0 ;;
        esac
        printf '%s\\n' "$@" > agent-arguments
        while :; do sleep 1; done
        """.write(to: folder.appending(path: "stub.txt"), atomically: true, encoding: .utf8)
    }

    private func assertDefaultLaunchArguments(in folder: URL, skipsPrompts: Bool) throws {
        let arguments = try String(contentsOf: folder.appending(path: "agent-arguments"), encoding: .utf8)
            .split(separator: "\n")
        XCTAssertFalse(arguments.contains("--model"), "The harness chooses its own model")
        XCTAssertFalse(arguments.contains("--effort"), "The harness chooses its own effort")
        XCTAssertEqual(arguments.contains("--dangerously-skip-permissions"), skipsPrompts)
    }

    @MainActor
    private func launchElement(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
