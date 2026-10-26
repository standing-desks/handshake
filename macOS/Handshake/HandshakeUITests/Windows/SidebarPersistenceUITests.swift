import XCTest

extension HandshakeUITests {
    @MainActor
    func testSidebarDefaultsClosedAndRemembersVisibilityAfterRelaunch() throws {
        let folder = try makeTestFolder(prefix: "HandshakeSidebarPersistence")
        let app = try makeApp(lastOpenFolder: folder)
        app.launch()
        defer { app.terminate() }

        let toggle = sidebarToggle(in: app)
        let sidebar = app.scrollViews["sidebarViewport"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(sidebar.exists, "An unsaved sidebar should start closed")
        toggle.click()
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), app.debugDescription)

        quitAndRelaunchForSidebar(in: app)
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "Restore the saved open state")
        app.typeKey("s", modifierFlags: [.command, .control])
        XCTAssertTrue(sidebar.waitForNonExistence(timeout: 5), app.debugDescription)

        quitAndRelaunchForSidebar(in: app)
        XCTAssertFalse(sidebar.exists, "Restore the saved closed state")
        toggle.click()
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), app.debugDescription)
        closeFolder(in: app)
        XCTAssertTrue(app.staticTexts["Welcome to Handshake"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", folder.lastPathComponent)).firstMatch.click()
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10), "Reopening the folder restores its sidebar")
    }

    @MainActor
    private func quitAndRelaunchForSidebar(in app: XCUIApplication) {
        app.menuBars.menuBarItems["Handshake"].click()
        app.menuItems["Quit Handshake"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), app.debugDescription)
        app.launch()
        XCTAssertTrue(sidebarToggle(in: app).waitForExistence(timeout: 10), app.debugDescription)
    }
}
