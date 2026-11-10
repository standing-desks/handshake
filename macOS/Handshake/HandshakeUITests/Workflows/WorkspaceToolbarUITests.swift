import XCTest

extension HandshakeUITests {
    @MainActor
    func testWorkspaceToolbarGroupsStayReachableInCompactWindows() throws {
        let folder = try makeTestFolder(prefix: "Handshake toolbar")
        let app = try makeApp(lastOpenFolder: folder, sidebarTabs: true)
        app.launchEnvironment["SHELL"] = "/bin/sh"
        app.launch()
        defer { app.terminate() }
        let terminal = app.buttons["workflowChoice-Terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1000, height: 650))
        let right = app.buttons["splitTerminalRight"]
        let down = app.buttons["splitTerminalDown"]
        terminal.click()
        let ready = expectation(for: NSPredicate { _, _ in right.isEnabled && down.isEnabled }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        let controls = [
            right, down, app.buttons["newWorkflow"], app.buttons["newBrowserTab"], app.buttons["tabSwitcher"],
        ]
        for control in controls {
            XCTAssertTrue(control.isHittable, control.debugDescription)
            XCTAssertGreaterThanOrEqual(control.frame.width, 28)
            XCTAssertGreaterThanOrEqual(control.frame.height, 28)
        }
        for (first, second) in zip(controls, controls.dropFirst()) {
            XCTAssertLessThanOrEqual(first.frame.maxX, second.frame.minX)
        }
        attachWindow(in: app, name: "Native toolbar groups")
        right.click()
        XCTAssertTrue(app.buttons["closeTerminalPane-2"].waitForExistence(timeout: 5))
        down.click()
        XCTAssertTrue(app.buttons["closeTerminalPane-3"].waitForExistence(timeout: 5))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 480, height: 420))
        attachWindow(in: app, name: "Compact native toolbar")
        app.menuBars.menuBarItems["View"].click()
        app.menuItems["Find Open Tab…"].click()
        let search = app.textFields["tabSwitcherSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
        // All toolbar commands remain available in the menu bar when space is constrained.
        app.menuBars.menuBarItems["View"].click()
        XCTAssertTrue(app.menuItems["Split Right"].isEnabled)
        XCTAssertTrue(app.menuItems["Split Down"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])
    }
}
