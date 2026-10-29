import XCTest

extension HandshakeUITests {
    @MainActor
    func testSidebarTabsNestUnderSessionsMoveWithUndoAndSwitchLayouts() throws {
        let folder = try makeTestFolder(prefix: "HandshakeSidebarTabs")
        let app = try makeApp(lastOpenFolder: folder, sidebarTabs: true)
        app.launchEnvironment["SHELL"] = "/bin/sh"
        app.launch()
        defer { app.terminate() }
        // A folder that hasn't chosen opens with the sidebar docked, and tabs are rows under their session.
        let first = app.buttons["workflowTab-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.scrollViews["sidebarViewport"].exists)
        XCTAssertTrue(app.buttons["sessionDisclosure-1"].exists)
        app.buttons["newWorkflow"].click()
        let second = app.buttons["workflowTab-2"]
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        waitForSidebarValue(of: second, containing: "Selected")
        app.buttons["newSession"].click()
        let secondSession = app.buttons["sessionRow-2"]
        XCTAssertTrue(secondSession.waitForExistence(timeout: 5))
        waitForSidebarValue(of: secondSession, containing: "Selected")

        // Moving a tab puts its row under the other session, and Undo returns it.
        second.rightClick()
        app.menuItems["Move to Session"].hover()
        app.menuItems["Session 2"].click()
        waitForRow(second, below: true, secondSession)
        app.menuBars.menuBarItems["Edit"].click()
        let undo = app.menuItems["undo:"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), app.debugDescription)
        undo.click()
        waitForRow(second, below: false, secondSession)

        // Choosing a tab in another session switches to that session.
        secondSession.click()
        waitForSidebarValue(of: secondSession, containing: "Selected")
        second.click()
        waitForSidebarValue(of: app.buttons["sessionRow-1"], containing: "Selected")
        waitForSidebarValue(of: second, containing: "Selected")

        // The layout switches from a tab's menu and back from the View menu.
        first.rightClick()
        app.menuItems["Show Tabs at the Top"].click()
        XCTAssertTrue(app.buttons["sessionDisclosure-1"].waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["workflowTab-2"].waitForExistence(timeout: 5))
        app.menuBars.menuBarItems["View"].click()
        app.menuItems["Tabs in Sidebar"].click()
        XCTAssertTrue(app.buttons["sessionDisclosure-1"].waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    func testMinimizedSidebarRailPeeksAndDocks() throws {
        let folder = try makeTestFolder(prefix: "HandshakeSidebarRail")
        let app = try makeApp(lastOpenFolder: folder, sidebarTabs: true)
        app.launchEnvironment["SHELL"] = "/bin/sh"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10), app.debugDescription)
        setSidebar(open: false, in: app)
        let rail = app.descendants(matching: .any)["sidebarRailContainer"]
        let peek = app.descendants(matching: .any)["sidebarPeek"]
        XCTAssertTrue(rail.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["rail-workflowTab-1"].exists)

        // Resting on the rail opens the peek over the content; leaving it returns to the rail.
        app.buttons["railSession-1"].hover()
        XCTAssertTrue(peek.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.buttons["sessionRow-1"].exists)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).hover()
        XCTAssertTrue(rail.waitForExistence(timeout: 3), app.debugDescription)

        // The sidebar button docks it again.
        setSidebar(open: true, in: app)
        XCTAssertTrue(rail.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func waitForSidebarValue(of element: XCUIElement, containing value: String) {
        let matched = expectation(
            for: NSPredicate { _, _ in (element.value as? String)?.contains(value) == true }, evaluatedWith: nil)
        wait(for: [matched], timeout: 5)
    }

    @MainActor
    private func waitForRow(_ row: XCUIElement, below: Bool, _ session: XCUIElement) {
        let placed = expectation(
            for: NSPredicate { _, _ in row.exists && (row.frame.minY > session.frame.minY) == below },
            evaluatedWith: nil)
        wait(for: [placed], timeout: 5)
    }
}
