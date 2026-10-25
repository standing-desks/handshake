import XCTest

extension HandshakeUITests {
    @MainActor
    func testFooterTracksBranchSelectionAndFrozenExitTime() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "HandshakeUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: folder.appending(path: ".git/objects"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: folder.appending(path: ".git/refs/heads"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let head = folder.appending(path: ".git/HEAD")
        try "ref: refs/heads/footer-initial\n".write(to: head, atomically: true, encoding: .utf8)
        let app = try makeApp(lastOpenFolder: folder)
        app.launch()
        XCTAssertTrue(app.buttons["newWorkflow"].waitForExistence(timeout: 10), app.debugDescription)
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 900, height: 620))
        XCTAssertTrue(app.staticTexts["footer-initial"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Draft"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["workflowChoice-Terminal"].click()
        XCTAssertTrue(app.staticTexts["Running"].waitForExistence(timeout: 10), app.debugDescription)
        app.typeText("exit\r")
        XCTAssertTrue(app.staticTexts["Exited"].waitForExistence(timeout: 10), app.debugDescription)
        let elapsed = app.staticTexts["workflowElapsed"]
        let frozen = elapsed.value as? String
        XCTAssertNotNil(frozen)
        app.buttons["newWorkflow"].click()
        XCTAssertTrue(app.staticTexts["Draft"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["workflowTab-1"].click()
        XCTAssertTrue(app.staticTexts["Exited"].waitForExistence(timeout: 10), app.debugDescription)
        try "ref: refs/heads/footer-updated\n".write(to: head, atomically: true, encoding: .utf8)
        XCTAssertTrue(app.staticTexts["footer-updated"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(elapsed.value as? String, frozen)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Status footer"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
    }
}
