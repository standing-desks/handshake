import XCTest

extension HandshakeUITests {
    @MainActor
    func testKiroLaunchesRecordsTracesAndResumesEachConversation() throws {
        let folder = try makeTestFolder(prefix: "HandshakeKiroUITests")
        try writeKiroFixture(in: folder)
        let app = try makeApp(lastOpenFolder: folder)
        defer { app.terminate() }
        let root = folder.appending(path: "native")
        app.launchEnvironment["SHELL"] = "/bin/sh"
        app.launchEnvironment["KIRO_HOME"] = root.path
        app.launchEnvironment["HANDSHAKE_HARNESS_PATH"] = "\(folder.path)/bin:/usr/bin:/bin"
        app.launch()
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10), app.debugDescription)
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1100, height: 800))
        chooseHarness("kiro", displayName: "Kiro CLI", in: app)
        waitForKiroLaunches(1, in: folder, app: app)
        let first = try XCTUnwrap(kiroLaunches(in: folder).first)
        XCTAssertFalse(first.yolo)
        app.typeText("Kiro first task\r")
        waitForFile(folder.appending(path: "kiro-input-\(first.session)"), containing: "Kiro first task", in: app)
        app.buttons["newWorkflow"].click()
        let yolo = app.checkBoxes["singleAgentYolo"]
        XCTAssertTrue(yolo.waitForExistence(timeout: 10))
        yolo.click()
        chooseHarness("kiro", displayName: "Kiro CLI", in: app)
        waitForKiroLaunches(2, in: folder, app: app)
        let second = try XCTUnwrap(kiroLaunches(in: folder).last)
        XCTAssertTrue(second.yolo)
        XCTAssertNotEqual(first.session, second.session)
        app.typeText("Kiro second task\r")
        waitForFile(folder.appending(path: "kiro-input-\(second.session)"), containing: "Kiro second task", in: app)
        try assertKiroResumeIsolation([first, second], in: folder, app: app)
        app.buttons["workflowTab-1"].click()
        app.typeText("Kiro resumed first task\r")
        waitForFile(
            folder.appending(path: "kiro-input-\(first.session)"), containing: "Kiro resumed first task", in: app)
        let otherInput = try String(contentsOf: folder.appending(path: "kiro-input-\(second.session)"), encoding: .utf8)
        XCTAssertFalse(otherInput.contains("resumed first"))
        app.buttons["tracesHeader"].click()
        let step = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'traceSpan-' AND label CONTAINS 'Kiro first task'")
        )
        .firstMatch
        XCTAssertTrue(step.waitForExistence(timeout: 10), app.debugDescription)
        step.click()
        attachScreenshot(of: app, named: "Kiro conversation resumed with its saved prompt trace")
        assertKiroCancellation(first, keeping: second, root: root, app: app)
    }
    @MainActor
    private func assertKiroResumeIsolation(_ originals: [KiroLaunch], in folder: URL, app: XCUIApplication) throws {
        app.terminate()
        app.launch()
        waitForKiroLaunches(4, in: folder, app: app)
        let resumed = kiroLaunches(in: folder).filter(\.resumed)
        XCTAssertEqual(Set(resumed.map(\.session)), Set(originals.map(\.session)))
        for original in originals {
            let restored = try XCTUnwrap(resumed.first { $0.session == original.session })
            XCTAssertEqual(restored.profile, original.profile, "Each native conversation keeps its own profile")
        }
    }

    @MainActor
    private func assertKiroCancellation(
        _ first: KiroLaunch, keeping second: KiroLaunch, root: URL, app: XCUIApplication
    ) {
        app.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Cancelled"].waitForExistence(timeout: 10), app.debugDescription)
        let profile = root.appending(path: "agents/\(first.profile).json")
        let removed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !FileManager.default.fileExists(atPath: profile.path) }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appending(path: "agents/\(second.profile).json").path))
    }

}
