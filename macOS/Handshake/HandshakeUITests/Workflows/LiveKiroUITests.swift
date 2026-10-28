import XCTest

extension HandshakeUITests {
    /// Opt-in authenticated trial; the fixture identifies an isolated folder and native CLI wrapper.
    @MainActor
    func testLiveKiroRetainsConversationAndFreshHooksAfterRelaunch() throws {
        let (folder, app) = try makeLiveKiroApp()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: "first.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: "second.txt").path))
        app.launch()
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 15))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1150, height: 850))
        let yolo = app.checkBoxes["singleAgentYolo"]
        XCTAssertTrue(yolo.waitForExistence(timeout: 10))
        yolo.click()
        chooseHarness("kiro", displayName: "Kiro CLI", in: app)
        let initial =
            "Kiro live check: remember the fictional token ORION_1847. "
            + "Write first.txt containing exactly KIRO_FIRST_OK, then reply done.\r"
        app.typeText(initial)
        waitForLiveKiroFile(folder.appending(path: "first.txt"), containing: "KIRO_FIRST_OK")
        assertLiveKiroResponse("Kiro live check", in: app)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 20))
        let followUp =
            "Resume check: without reading any files, write second.txt with the fictional token "
            + "I asked you to remember, then reply done.\r"
        app.typeText(followUp)
        waitForLiveKiroFile(folder.appending(path: "second.txt"), containing: "ORION_1847")
        assertLiveKiroResponse("Resume check", in: app)
        let launches = try String(contentsOf: folder.appending(path: "live-launches.jsonl"), encoding: .utf8)
        XCTAssertTrue(launches.contains("--resume-id"), launches)
        attachScreenshot(of: app, named: "Authenticated Kiro resume and fresh native response trace")
    }

    @MainActor
    func testLiveKiroWorkflowUsesRoleInstructionsAndExplicitCompletion() throws {
        let (folder, app) = try makeLiveKiroApp()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: "workflow-result.txt").path))
        app.launch()
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 15))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1200, height: 850))
        let choice = app.descendants(matching: .any).matching(identifier: "workflowChoice-Adversarial").firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 15))
        choice.click()
        for role in ["implementer", "reviewer"] {
            let picker = app.descendants(matching: .any).matching(identifier: "roleHarness-\(role)-0").firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout: 10), app.debugDescription)
            picker.click()
            app.menuItems["Kiro CLI"].click()
        }
        let start = app.descendants(matching: .any).matching(identifier: "workflowStart").firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.click()
        XCTAssertTrue(app.buttons["workflowMarkDone"].waitForExistence(timeout: 20), app.debugDescription)
        let task =
            "Write workflow-result.txt containing exactly KIRO_WORKFLOW_OK. "
            + "The reviewer should accept if it matches. Only change that file.\r"
        app.typeText(task)
        XCTAssertTrue(app.staticTexts["Completed"].waitForExistence(timeout: 180), app.debugDescription)
        let contents = try String(contentsOf: folder.appending(path: "workflow-result.txt"), encoding: .utf8)
        XCTAssertTrue(contents.contains("KIRO_WORKFLOW_OK"), contents)
        attachScreenshot(of: app, named: "Authenticated Kiro roles completed through native completion commands")
    }

    @MainActor
    private func makeLiveKiroApp() throws -> (URL, XCUIApplication) {
        let file = URL(filePath: "/tmp/handshake-kiro-live-fixture.json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw XCTSkip("Prepare an authenticated Kiro fixture to run this trial.")
        }
        let fixture = try JSONDecoder().decode(LiveKiroFixture.self, from: Data(contentsOf: file))
        let folder = URL(filePath: fixture.folder)
        let app = try makeApp(lastOpenFolder: folder)
        addTeardownBlock { await MainActor.run { app.terminate() } }
        app.launchEnvironment["SHELL"] = "/bin/sh"
        app.launchEnvironment["KIRO_HOME"] = fixture.profileRoot
        app.launchEnvironment["HANDSHAKE_HARNESS_PATH"] = fixture.harnessPath
        return (folder, app)
    }

    @MainActor
    private func assertLiveKiroResponse(_ prompt: String, in app: XCUIApplication) {
        app.buttons["tracesHeader"].click()
        let span = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'traceSpan-' AND label CONTAINS %@", prompt)
        ).firstMatch
        XCTAssertTrue(span.waitForExistence(timeout: 15), app.debugDescription)
        span.click()
        let finished = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show output: Finished responding'"))
            .firstMatch
        XCTAssertTrue(finished.waitForExistence(timeout: 60), app.debugDescription)
        app.buttons["tracesHeader"].click()
    }

    private func waitForLiveKiroFile(_ file: URL, containing marker: String) {
        let written = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                (try? String(contentsOf: file, encoding: .utf8).contains(marker)) == true
            }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [written], timeout: 120), .completed)
    }
}

private struct LiveKiroFixture: Decodable {
    let folder: String
    let harnessPath: String
    let profileRoot: String
}
