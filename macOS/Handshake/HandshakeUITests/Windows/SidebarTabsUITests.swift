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
    func testCollapsedSidebarExpandsOnHoverAndPreservesTabs() throws {
        let folder = try makeTestFolder(prefix: "HandshakeSidebarRail")
        let app = try makeApp(lastOpenFolder: folder, sidebarTabs: true)
        app.launchEnvironment["SHELL"] = "/bin/sh"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10), app.debugDescription)
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1000, height: 420))
        for id in 2...10 {
            app.typeKey("t", modifierFlags: .command)
            XCTAssertTrue(app.buttons["workflowTab-\(id)"].waitForExistence(timeout: 5), app.debugDescription)
        }
        setSidebar(open: false, in: app)
        let rail = app.descendants(matching: .any)["sidebarRailContainer"]
        XCTAssertTrue(rail.waitForExistence(timeout: 5), app.debugDescription)
        let tab = app.buttons["rail-workflowTab-10"]
        assertRailTabVisible(tab, in: rail)
        XCTAssertLessThanOrEqual(abs(rail.frame.minX - app.windows.firstMatch.frame.minX), 2)
        waitForSidebarValue(of: tab, containing: "Selected")
        checkHoverTabSelection(in: app, rail: rail)
        moveOutsideRail(in: app)
        waitForRail(rail, expanded: false)
        app.typeText("printf rail_input > rail-input\r")
        waitForFile(folder.appending(path: "rail-input"), containing: "rail_input", in: app)
        let selected = app.buttons["rail-workflowTab-9"]
        checkRailEscape(in: app, rail: rail, tab: selected)
        moveOutsideRail(in: app)
        setSidebar(open: true, in: app)
        let docked = app.buttons["workflowTab-9"]
        XCTAssertTrue(docked.waitForExistence(timeout: 5) && docked.isHittable, app.debugDescription)
        waitForSidebarValue(of: docked, containing: "Selected")
        setSidebar(open: false, in: app)
        assertRailTabVisible(selected, in: rail)
        waitForSidebarValue(of: selected, containing: "Selected")
    }

    @MainActor
    private func checkHoverTabSelection(in app: XCUIApplication, rail: XCUIElement) {
        let workspaceWidth = app.scrollViews["workspaceViewport"].frame.width
        let tab = app.buttons["rail-workflowTab-10"]
        let originalFrame = tab.frame
        tab.hover()
        waitForRail(rail, expanded: true)
        XCTAssertGreaterThan(rail.frame.width, 200)
        XCTAssertEqual(tab.frame.minX, originalFrame.minX, accuracy: 1)
        XCTAssertEqual(tab.frame.minY, originalFrame.minY, accuracy: 1)
        XCTAssertEqual(app.scrollViews["workspaceViewport"].frame.width, workspaceWidth, accuracy: 1)
        XCTAssertFalse(app.scrollViews["sidebarViewport"].exists)
        attachWindow(in: app, name: "Tab rail expanded on hover with session and tab titles")
        let selected = app.buttons["rail-workflowTab-9"]
        let rowPosition = selected.frame.minY
        selected.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).click()
        waitForSidebarValue(of: selected, containing: "Selected")
        XCTAssertEqual(selected.frame.minY, rowPosition, accuracy: 1)
        XCTAssertFalse(app.scrollViews["sidebarViewport"].exists)
        selected.rightClick()
        let rename = app.menuItems["Rename…"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5), app.debugDescription)
        rename.hover()
        waitForRail(rail, expanded: true)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    private func checkRailEscape(in app: XCUIApplication, rail: XCUIElement, tab: XCUIElement) {
        tab.hover()
        waitForRail(rail, expanded: true)
        app.typeKey(.escape, modifierFlags: [])
        waitForRail(rail, expanded: false)
        XCTAssertFalse(app.scrollViews["sidebarViewport"].exists)
        moveOutsideRail(in: app)
        tab.hover()
        waitForRail(rail, expanded: true)
    }

    @MainActor
    private func moveOutsideRail(in app: XCUIApplication) {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).hover()
    }

    @MainActor
    private func waitForRail(_ rail: XCUIElement, expanded: Bool) {
        let resized = expectation(
            for: NSPredicate { _, _ in
                rail.exists && (expanded ? rail.frame.width > 200 : rail.frame.width < 80)
            }, evaluatedWith: nil)
        wait(for: [resized], timeout: 5)
    }

    @MainActor
    private func assertRailTabVisible(_ tab: XCUIElement, in rail: XCUIElement) {
        let visible = expectation(
            for: NSPredicate { _, _ in
                guard tab.exists, tab.isHittable, rail.exists else { return false }
                return tab.frame.minY >= rail.frame.minY && tab.frame.maxY <= rail.frame.maxY + 1
            }, evaluatedWith: nil)
        wait(for: [visible], timeout: 5)
        XCTAssertGreaterThanOrEqual(tab.frame.height, 28)
        XCTAssertGreaterThanOrEqual(tab.frame.width, 28)
    }

    @MainActor
    private func waitForSidebarValue(of element: XCUIElement, containing value: String) {
        let matched = expectation(
            for: NSPredicate { _, _ in element.exists && (element.value as? String)?.contains(value) == true },
            evaluatedWith: nil)
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
