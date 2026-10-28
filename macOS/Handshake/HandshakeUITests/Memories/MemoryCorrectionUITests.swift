import XCTest

extension HandshakeUITests {
    @MainActor
    func testMemoryCorrectionPreservesDraftWhenSelectedMemoryChanges() throws {
        let fixture = try makeAMISFixture()
        let app = fixture.app
        app.launch()
        defer { app.terminate() }
        openHandshakeMemory(in: app)
        waitForHandshakeText("1 project memories", identifier: "handshakeMemoryCount", in: app)
        app.buttons["handshakeMemoryCount"].click()
        app.staticTexts["Demo account"].firstMatch.rightClick()
        app.menuItems["Correct memory…"].click()
        let editor = app.textViews["memoryCorrectionText"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        let draft = "Use maple-418 for this project."
        editor.typeText(draft)
        try "# Demo account\nA newer native change.\n".write(
            to: fixture.source.appending(path: "demo.md"), atomically: true, encoding: .utf8)
        let save = app.buttons["saveMemoryCorrection"]
        let enabled = expectation(for: NSPredicate { _, _ in save.isEnabled }, evaluatedWith: nil)
        wait(for: [enabled], timeout: 5)
        save.click()
        let failure = app.staticTexts["memoryCorrectionFailure"]
        XCTAssertTrue(failure.waitForExistence(timeout: 10), app.debugDescription)
        if staticTextValue(failure).contains("Memory is updating") { save.click() }
        let conflict = expectation(
            for: NSPredicate { _, _ in failure.exists && staticTextValue(failure).contains("native memory file changed")
            },
            evaluatedWith: nil)
        wait(for: [conflict], timeout: 10)
        XCTAssertTrue(editor.exists)
        XCTAssertEqual(editor.value as? String, draft)
        app.buttons["Cancel"].click()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testMemoryCorrectionReachesRunningAgentUnderPressureAndSurvivesRelaunch() throws {
        let fixture = try makeAMISFixture()
        for index in 0..<24 {
            try ("# Background \(index)\n" + String(repeating: "Unrelated project note. ", count: 100)).write(
                to: fixture.source.appending(path: "noise-\(index).md"), atomically: true, encoding: .utf8)
        }
        let bin = try writeMemoryPromptAgent(in: fixture.folder)
        let app = fixture.app
        app.launchEnvironment["HANDSHAKE_HARNESS_PATH"] = "\(bin.path):/usr/bin:/bin"
        app.launch()
        defer { app.terminate() }
        startMemoryPromptAgent(fixture: fixture, bin: bin)
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 820, height: 573))
        let pidFile = fixture.folder.appending(path: "agent-pid")
        let started = expectation(
            for: NSPredicate { _, _ in
                (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap(Int32.init).map { $0 > 0 } == true
            }, evaluatedWith: nil)
        wait(for: [started], timeout: 10)
        let originalPID = try String(contentsOf: pidFile, encoding: .utf8)
        app.typeText("Which demo account should I use?\r")
        let response = fixture.folder.appending(path: "prompt-memory-response.json")
        waitForFile(response, containing: "maple-417", in: app)
        openHandshakeMemory(in: app)
        waitForHandshakeText("25 project memories", identifier: "handshakeMemoryCount", in: app)
        enterAndSaveCorrection(in: app)
        app.buttons["workflowTab-2"].click()
        app.typeText("Which demo account should I use?\r")
        waitForFile(response, containing: "maple-418", in: app)
        try assertBoundedCorrection(response)
        XCTAssertEqual(try String(contentsOf: pidFile, encoding: .utf8), originalPID)
        app.terminate()
        try FileManager.default.removeItem(at: response)
        app.launch()
        XCTAssertTrue(app.buttons["workflowTab-2"].waitForExistence(timeout: 15))
        app.buttons["workflowTab-2"].click()
        app.typeText("Which demo account should I use?\r")
        waitForFile(response, containing: "maple-418", in: app)
        try assertBoundedCorrection(response)
        openHandshakeMemory(in: app)
        waitForHandshakeText("25 project memories", identifier: "handshakeMemoryCount", in: app)
        XCTAssertTrue(app.buttons["handshakeMemoryArchive"].exists)
        attachScreenshot(of: app, named: "Correction survives relaunch and retains the old memory in archive")
    }

    @MainActor
    private func enterAndSaveCorrection(in app: XCUIApplication) {
        app.buttons["handshakeMemoryCount"].click()
        let title = app.staticTexts["Demo account"].firstMatch
        revealHandshakeDetail(title, in: app)
        title.rightClick()
        app.menuItems["Correct memory…"].click()
        let editor = app.textViews["memoryCorrectionText"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let save = app.buttons["saveMemoryCorrection"]
        XCTAssertFalse(save.isEnabled)
        editor.click()
        editor.typeText("# Demo account\nUse maple-418 for this fictional project. The old account is retired.")
        attachScreenshot(of: app, named: "Correct a shared memory using the native editor")
        XCTAssertTrue(save.isEnabled)
        save.click()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 10), app.debugDescription)
    }

    @MainActor
    private func startMemoryPromptAgent(fixture: HandshakeMemoryFixture, bin: URL) {
        let app = fixture.app
        let terminal = app.descendants(matching: .any).matching(identifier: "workflowChoice-Terminal").firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        terminal.click()
        app.typeText("cat memory-prompt-agent.py > bin/claude; chmod +x bin/claude\r")
        let installed = expectation(
            for: NSPredicate { _, _ in FileManager.default.isExecutableFile(atPath: bin.appending(path: "claude").path)
            },
            evaluatedWith: nil)
        wait(for: [installed], timeout: 10)
        app.buttons["newWorkflow"].click()
        chooseHarness("claudeCode", displayName: "Claude Code", in: app)
    }

    private func assertBoundedCorrection(_ response: URL) throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: response)) as? [String: Any])
        let output = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        let context = try XCTUnwrap(output["additionalContext"] as? String)
        XCTAssertLessThanOrEqual(context.utf8.count, 8_192)
        XCTAssertTrue(context.contains("maple-418"))
        XCTAssertFalse(context.contains("maple-417"))
        XCTAssertTrue(context.contains("Current correction replaces"))
    }
}
