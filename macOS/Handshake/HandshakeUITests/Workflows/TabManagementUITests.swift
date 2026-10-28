import Darwin
import XCTest

extension HandshakeUITests {
    @MainActor
    func testTabManagementIsStandardAndIgnoresRetiredSettings() throws {
        let folder = try makeTestFolder(prefix: "HandshakeStandardTabs")
        let app = try managedTabApp(folder: folder)
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["tabSwitcher"].waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        let section = app.sheets.radioButtons["Feature flags"]
        XCTAssertTrue(section.waitForExistence(timeout: 10))
        section.click()
        XCTAssertFalse(
            app.descendants(matching: .any).matching(identifier: "featureFlag-tabManagement").firstMatch.exists)
        app.buttons["closeSettings"].click()
        app.terminate()
        let root = URL(filePath: try XCTUnwrap(app.launchEnvironment["XDG_CONFIG_HOME"]))
        let config = root.appending(path: "handshake/config.toml")
        try "[feature_flags]\ntab_management = false\n".write(to: config, atomically: true, encoding: .utf8)
        app.launch()
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["tabSwitcher"].waitForExistence(timeout: 5))
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "[feature_flags]\ntab_management = false\n")
    }

    @MainActor
    func testManagedTabsRenameReorderPinNavigateAndReopenWithoutRestarting() throws {
        let folder = try makeTestFolder(prefix: "HandshakeManagedTabs")
        let app = try managedTabApp(folder: folder)
        app.launch()
        defer { app.terminate() }
        let first = app.buttons["workflowTab-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 10), app.debugDescription)
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1200, height: 800))
        first.doubleClick()
        let name = app.textFields["tabName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), app.debugDescription)
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("API fix")
        app.sheets.buttons["Rename"].click()
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))
        app.buttons["workflowChoice-Terminal"].click()
        app.typeText("echo TAB_HISTORY_MARKER; echo $$ > original.pid\r")
        let processID = try writtenProcessID(in: folder.appending(path: "original.pid"), app: app)
        defer { endProcessIfRunning(processID) }
        XCTAssertEqual(first.label, "API fix", "Activation preserves the custom title")
        try arrangeAndFindManagedTabs(in: app, folder: folder, processID: processID)
        let third = app.buttons["workflowTab-3"]
        app.typeKey("w", modifierFlags: [.command, .shift])
        XCTAssertTrue(first.waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(processEnds(processID))
        app.typeKey("t", modifierFlags: [.command, .shift])
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["reopenedWorkflowHistory"].waitForExistence(timeout: 10))
        let history = app.textViews["terminalHistoryText"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        XCTAssertTrue((history.value as? String ?? "").contains("TAB_HISTORY_MARKER"))
        attachScreenshot(of: app, named: "Managed tabs with pinned tab and reopened history")
        app.menuBars.menuBarItems["Handshake"].click()
        app.menuItems["Quit Handshake"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        waitForTab(first, valueContaining: "Selected", in: app)
        waitForTab(third, valueContaining: "Pinned", in: app)
        XCTAssertLessThan(third.frame.minX, first.frame.minX)
        XCTAssertTrue(app.buttons["restartClosedTerminal"].waitForExistence(timeout: 5))
        try verifyHistoryAndExplicitRestart(in: app, folder: folder, originalProcessID: processID)
    }

    @MainActor
    private func verifyHistoryAndExplicitRestart(
        in app: XCUIApplication, folder: URL, originalProcessID: Int32
    ) throws {
        XCTAssertTrue(app.buttons["tabSwitcher"].exists)
        XCTAssertTrue(app.buttons["restartClosedTerminal"].exists)
        XCTAssertTrue(processEnds(originalProcessID))
        app.buttons["restartClosedTerminal"].click()
        let fresh = app.buttons["workflowTab-4"]
        XCTAssertTrue(fresh.waitForExistence(timeout: 5))
        waitForTab(fresh, valueContaining: "Selected", in: app)
        XCTAssertFalse(app.buttons["workflowChoice-Terminal"].exists)
        app.typeText("echo fresh > explicitly-started; echo $$ > fresh.pid\r")
        waitForFile(folder.appending(path: "explicitly-started"), containing: "fresh", in: app)
        let freshProcessID = try writtenProcessID(in: folder.appending(path: "fresh.pid"), app: app)
        defer { endProcessIfRunning(freshProcessID) }
        XCTAssertNotEqual(freshProcessID, originalProcessID)
    }

    @MainActor
    func testManagedTabsKeepSplitNeighborAndRestoreFilesAfterQuit() throws {
        let folder = try makeTestFolder(prefix: "HandshakeManagedSplit")
        let file = folder.appending(path: "notes.txt")
        try "saved notes".write(to: file, atomically: true, encoding: .utf8)
        let app = try managedTabApp(folder: folder)
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1200, height: 800))
        app.buttons["workflowChoice-Terminal"].click()
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(app.buttons["workflowTab-2"].waitForExistence(timeout: 5))
        app.buttons["workflowTab-1"].click()
        app.typeKey("p", modifierFlags: [.command, .shift])
        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(app.buttons["closeTerminalPane-3"].waitForExistence(timeout: 5))
        app.buttons["closeTerminalPane-1"].click()
        XCTAssertTrue(app.buttons["workflowTab-3"].waitForExistence(timeout: 5))
        waitForTab(app.buttons["workflowTab-3"], valueContaining: "Selected", in: app)
        waitForTab(app.buttons["workflowTab-3"], valueContaining: "Pinned", in: app)
        app.typeKey("p", modifierFlags: [.command, .shift])
        setSidebar(open: true, in: app)
        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "fileRow-\(file.path)")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.click()
        let fileTab = app.buttons.matching(NSPredicate(format: "identifier == %@", "fileTab-\(file.path)")).firstMatch
        XCTAssertTrue(fileTab.waitForExistence(timeout: 5))
        app.typeKey(.leftArrow, modifierFlags: [.command, .option, .shift])
        app.typeKey(.leftArrow, modifierFlags: [.command, .option, .shift])
        app.menuBars.menuBarItems["Handshake"].click()
        app.menuItems["Quit Handshake"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        XCTAssertTrue(fileTab.waitForExistence(timeout: 10))
        waitForTab(fileTab, valueContaining: "Selected", in: app)
        XCTAssertLessThan(fileTab.frame.minX, app.buttons["workflowTab-3"].frame.minX)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(fileTab.waitForNonExistence(timeout: 5))
        app.menuBars.menuBarItems["File"].click()
        let reopen = app.menuItems["Reopen Closed Tab"]
        XCTAssertTrue(reopen.exists, app.debugDescription)
        XCTAssertTrue(reopen.isEnabled, app.debugDescription)
        reopen.click()
        XCTAssertTrue(fileTab.waitForExistence(timeout: 5), app.debugDescription)
        waitForTab(fileTab, valueContaining: "Selected", in: app)
    }

    @MainActor
    func testManagedTabsConfirmBeforeStoppingARunningAgent() throws {
        let folder = try makeTestFolder(prefix: "HandshakeTabClose")
        try """
        case "$1" in --help|--list-models) exit 0 ;; esac
        echo $$ > agent.pid
        while read line; do :; done
        """.write(to: folder.appending(path: "stub.txt"), atomically: true, encoding: .utf8)
        let app = try managedTabApp(folder: folder)
        app.launchEnvironment["HANDSHAKE_HARNESS_PATH"] = "\(folder.path)/bin:/bin:/usr/bin"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
        app.buttons["workflowChoice-Terminal"].click()
        app.typeText(
            "mkdir bin; printf '#!/bin/sh\\n' > bin/pi; cat stub.txt >> bin/pi; "
                + "chmod +x bin/pi; echo ready > installed\r"
        )
        waitForFile(folder.appending(path: "installed"), containing: "ready", in: app)
        app.typeKey("t", modifierFlags: .command)
        chooseHarness("pi", in: app)
        let processID = try writtenProcessID(in: folder.appending(path: "agent.pid"), app: app)
        defer { endProcessIfRunning(processID) }
        app.typeKey("w", modifierFlags: .command)
        clickDialogButton("Cancel", in: app)
        XCTAssertTrue(app.buttons["workflowTab-2"].exists)
        XCTAssertEqual(kill(processID, 0), 0)
        app.typeKey("w", modifierFlags: .command)
        clickDialogButton("Close and Stop Agents", in: app)
        XCTAssertTrue(app.buttons["workflowTab-2"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(processEnds(processID))
    }

    @MainActor
    func testTabSwitcherSupportsKeyboardSelection() throws {
        let folder = try makeTestFolder(prefix: "HandshakeTabSwitcher")
        let app = try managedTabApp(folder: folder)
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(app.buttons["workflowTab-2"].waitForExistence(timeout: 5))
        app.typeKey("1", modifierFlags: .command)
        app.typeKey("a", modifierFlags: [.command, .shift])
        let search = app.textFields["tabSwitcherSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("workflow")
        search.typeKey(.downArrow, modifierFlags: [])
        waitForTab(app.buttons["switchTo-workflowTab-2"], valueContaining: "Highlighted", in: app)
        search.typeKey(.return, modifierFlags: [])
        waitForTab(app.buttons["workflowTab-2"], valueContaining: "Selected", in: app)
        app.typeText("echo selected > keyboard-selected\r")
        waitForFile(folder.appending(path: "keyboard-selected"), containing: "selected", in: app)
        XCTAssertEqual(app.buttons["workflowTab-2"].label, "Terminal")
    }

    @MainActor
    private func arrangeAndFindManagedTabs(in app: XCUIApplication, folder: URL, processID: Int32) throws {
        let first = app.buttons["workflowTab-1"]
        for id in 2...3 {
            app.typeKey("t", modifierFlags: .command)
            XCTAssertTrue(app.buttons["workflowTab-\(id)"].waitForExistence(timeout: 5))
            app.buttons["workflowChoice-Terminal"].click()
        }
        let second = app.buttons["workflowTab-2"]
        let third = app.buttons["workflowTab-3"]
        let named = expectation(
            for: NSPredicate { _, _ in
                second.label == "Terminal · 2" && third.label == "Terminal · 3"
            }, evaluatedWith: nil)
        wait(for: [named], timeout: 5)
        app.typeKey("p", modifierFlags: [.command, .shift])
        waitForTab(third, valueContaining: "Pinned", in: app)
        XCTAssertLessThan(third.frame.minX, first.frame.minX)
        app.typeKey("2", modifierFlags: .command)
        waitForTab(first, valueContaining: "Selected", in: app)
        app.typeKey(.rightArrow, modifierFlags: [.command, .option, .shift])
        XCTAssertLessThan(second.frame.minX, first.frame.minX)
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).click(
            forDuration: 0.1, thenDragTo: second.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)))
        let dragged = expectation(for: NSPredicate { _, _ in first.frame.minX < second.frame.minX }, evaluatedWith: nil)
        attachScreenshot(of: app, named: "Reordered tabs")
        wait(for: [dragged], timeout: 5)
        app.typeKey(.tab, modifierFlags: .control)
        waitForTab(second, valueContaining: "Selected", in: app)
        app.typeKey(.tab, modifierFlags: [.control, .shift])
        waitForTab(first, valueContaining: "Selected", in: app)
        app.typeText("echo $$ > after-move.pid\r")
        waitForFile(folder.appending(path: "after-move.pid"), containing: String(processID), in: app)
        app.typeKey("a", modifierFlags: [.command, .shift])
        let search = app.textFields["tabSwitcherSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("Terminal")
        // The renamed API tab also matches its Terminal type, between the other two results.
        search.typeKey(.downArrow, modifierFlags: [])
        search.typeKey(.downArrow, modifierFlags: [])
        waitForTab(app.buttons["switchTo-workflowTab-2"], valueContaining: "Highlighted", in: app)
        search.typeKey(.return, modifierFlags: [])
        waitForTab(second, valueContaining: "Selected", in: app)
        app.typeKey("a", modifierFlags: [.command, .shift])
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("API")
        search.typeKey(.return, modifierFlags: [])
        waitForTab(first, valueContaining: "Selected", in: app)
    }

    @MainActor
    func managedTabApp(folder: URL) throws -> XCUIApplication {
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["SHELL"] = "/bin/sh"
        return app
    }

    @MainActor
    func waitForTab(_ tab: XCUIElement, valueContaining value: String, in app: XCUIApplication) {
        let selected = expectation(
            for: NSPredicate { _, _ in (tab.value as? String ?? "").contains(value) }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed, app.debugDescription)
        XCTAssertTrue(tab.exists, app.debugDescription)
    }
}
