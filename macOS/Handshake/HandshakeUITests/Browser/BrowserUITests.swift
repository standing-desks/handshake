import XCTest

extension HandshakeUITests {
    @MainActor
    func testBrowserTabsShareRenamePinMoveReopenAndRestore() async throws {
        let folder = try makeTestFolder(prefix: "HandshakeBrowserTabs")
        let server = try BrowserFixtureServer(root: folder.appending(path: "site"))
        try await server.start()
        defer { server.stop() }
        let app = try managedTabApp(folder: folder)
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1200, height: 800))
        let create = app.buttons["newBrowserTab"]
        XCTAssertGreaterThanOrEqual(create.frame.minX, app.buttons["newWorkflow"].frame.maxX)
        XCTAssertLessThan(create.frame.minX - app.buttons["newWorkflow"].frame.maxX, 20)
        create.click()
        let first = browserTabs(in: app).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let firstID = first.identifier
        let address = app.textFields["browserAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        // Fresh-page focus accepts typing without clicking the address control.
        app.typeText(try server.url("a").absoluteString + "\r")
        waitForBrowserTitle("Page A", tab: first, in: app)
        let note = app.webViews.textFields["Page note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.click()
        note.typeText("keep my page state")
        app.typeKey("t", modifierFlags: [.command, .option])
        XCTAssertEqual(browserTabs(in: app).count, 2)
        let secondID = try XCTUnwrap(
            browserTabs(in: app).allElementsBoundByIndex.first { $0.identifier != firstID }?.identifier)
        navigateBrowser(to: try server.url("b"), in: app)
        waitForBrowserTitle("Page B", tab: app.buttons[secondID], in: app)
        app.buttons[firstID].click()
        XCTAssertEqual(app.webViews.textFields["Page note"].value as? String, "keep my page state")
        renameAndArrangeBrowser(firstID: firstID, secondID: secondID, in: app)
        attachScreenshot(of: app, named: "Browser tabs share rename pin move and retained page state")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.buttons[firstID].waitForNonExistence(timeout: 5))
        waitForTab(app.buttons[secondID], valueContaining: "Selected", in: app)
        app.typeKey("t", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.buttons[firstID].waitForExistence(timeout: 5))
        waitForTab(app.buttons[firstID], valueContaining: "Pinned", in: app)
        waitForTab(app.buttons[firstID], valueContaining: "Selected", in: app)
        XCTAssertEqual(app.buttons[firstID].label, "Reference docs")
        verifyRestoredBrowser(firstID: firstID, secondID: secondID, in: app)
    }

    @MainActor
    func testBrowserNavigationValidationSheetsAndContextualClose() async throws {
        let folder = try makeTestFolder(prefix: "HandshakeBrowserNavigation")
        let server = try BrowserFixtureServer(root: folder.appending(path: "site"))
        try await server.start()
        defer { server.stop() }
        let app = try managedTabApp(folder: folder)
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
        app.typeKey("t", modifierFlags: [.command, .option])
        let tab = browserTabs(in: app).firstMatch
        navigateBrowser(to: try server.url("a"), in: app)
        waitForBrowserTitle("Page A", tab: tab, in: app)
        navigateBrowser(draft: "not a website", in: app)
        XCTAssertTrue(app.staticTexts["browserFailure"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["browserAddress"].value as? String, "not a website")
        XCTAssertEqual(tab.label, "Page A")
        app.typeKey("l", modifierFlags: .command)
        XCTAssertEqual(app.textFields["browserAddress"].value as? String, try server.url("a").absoluteString)
        app.webViews.links["Go to B"].click()
        waitForBrowserTitle("Page B", tab: tab, in: app)
        app.typeKey("[", modifierFlags: .command)
        waitForBrowserTitle("Page A", tab: tab, in: app)
        app.typeKey("]", modifierFlags: .command)
        waitForBrowserTitle("Page B", tab: tab, in: app)
        app.typeKey("r", modifierFlags: .command)
        waitForBrowserTitle("Page B", tab: tab, in: app)
        checkNativeWebsiteSheets(in: app)
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.buttons["closeSettings"].waitForExistence(timeout: 5))
        app.menuBars.menuBarItems["Browser"].click()
        XCTAssertFalse(app.menuItems["Open Location…"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        app.buttons["closeSettings"].click()
        XCTAssertTrue(app.buttons["closeSettings"].waitForNonExistence(timeout: 5))
        attachScreenshot(of: app, named: "Browser native navigation controls and website sheets")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(tab.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.windows.firstMatch.exists)
        XCTAssertTrue(app.buttons["workflowTab-1"].exists)
    }

    @MainActor
    private func verifyRestoredBrowser(firstID: String, secondID: String, in app: XCUIApplication) {
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        XCTAssertTrue(app.buttons[firstID].waitForExistence(timeout: 10))
        waitForTab(app.buttons[firstID], valueContaining: "Selected", in: app)
        waitForTab(app.buttons[firstID], valueContaining: "Pinned", in: app)
        XCTAssertEqual(app.buttons[firstID].label, "Reference docs")
        XCTAssertTrue(app.buttons[secondID].exists)
        XCTAssertTrue(app.textFields["browserAddress"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func renameAndArrangeBrowser(firstID: String, secondID: String, in app: XCUIApplication) {
        app.typeKey("i", modifierFlags: [.command, .shift])
        let name = app.textFields["tabName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeKey("a", modifierFlags: .command)
        name.typeText("Reference docs")
        name.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.buttons[firstID].label, "Reference docs")
        app.typeKey(.rightArrow, modifierFlags: [.command, .option, .shift])
        XCTAssertGreaterThan(app.buttons[firstID].frame.minX, app.buttons[secondID].frame.minX)
        app.typeKey("p", modifierFlags: [.command, .shift])
        waitForTab(app.buttons[firstID], valueContaining: "Pinned", in: app)
        XCTAssertLessThan(app.buttons[firstID].frame.minX, app.buttons["workflowTab-1"].frame.minX)
        app.typeKey("a", modifierFlags: [.command, .shift])
        let search = app.textFields["tabSwitcherSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("Reference docs")
        search.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.webViews.textFields["Page note"].value as? String, "keep my page state")
    }

    @MainActor
    private func checkNativeWebsiteSheets(in app: XCUIApplication) {
        app.webViews.buttons["Show alert"].click()
        XCTAssertTrue(app.sheets.staticTexts["Fixture alert"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.sheets.staticTexts["127.0.0.1"].exists)
        app.sheets.buttons["OK"].click()
        app.webViews.buttons["Show confirm"].click()
        XCTAssertTrue(app.sheets.staticTexts["Fixture confirm"].waitForExistence(timeout: 5))
        app.sheets.buttons["Cancel"].click()
        app.webViews.buttons["Show prompt"].click()
        let input = app.textFields["browserPrompt"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.typeKey("a", modifierFlags: .command)
        input.typeText("native prompt")
        app.sheets.buttons["OK"].click()
        XCTAssertTrue(input.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func browserTabs(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "browserTab-"))
    }

    @MainActor
    func navigateBrowser(to url: URL, in app: XCUIApplication) { navigateBrowser(draft: url.absoluteString, in: app) }

    @MainActor
    func navigateBrowser(draft: String, in app: XCUIApplication) {
        app.typeKey("l", modifierFlags: .command)
        let address = app.textFields["browserAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.typeKey("a", modifierFlags: .command)
        address.typeText(draft)
        address.typeKey(.return, modifierFlags: [])
    }

    @MainActor
    func waitForBrowserTitle(_ title: String, tab: XCUIElement, in app: XCUIApplication) {
        let loaded = expectation(for: NSPredicate { _, _ in tab.label == title }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 10), .completed, app.debugDescription)
    }
}
