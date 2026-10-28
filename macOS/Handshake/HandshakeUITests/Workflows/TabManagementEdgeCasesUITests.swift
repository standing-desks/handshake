import XCTest

extension HandshakeUITests {
    @MainActor
    func testTabCreationButtonsMatchTabsAcrossAppearancesAndZoom() throws {
        for (appearance, scrollBars) in [
            ("Light", "Automatic"), ("Dark", "Automatic"), ("Light", "Always"), ("Dark", "Always"),
        ] {
            let folder = try makeTestFolder(prefix: "HandshakeTabControlHeight")
            let app = try managedTabApp(folder: folder)
            app.launchEnvironment["HANDSHAKE_TEST_APPEARANCE"] = appearance
            app.launchArguments += ["-AppleShowScrollBars", scrollBars]
            app.launch()
            defer { app.terminate() }
            XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10), app.debugDescription)
            resizeWindow(app.windows.firstMatch, to: CGSize(width: 920, height: 676))
            setSidebar(open: true, in: app)
            for id in 2...4 {
                app.buttons["newWorkflow"].click()
                XCTAssertTrue(app.buttons["workflowTab-\(id)"].waitForExistence(timeout: 5), app.debugDescription)
                waitForTab(app.buttons["workflowTab-\(id)"], valueContaining: "Selected", in: app)
            }
            let tab = app.buttons["workflowTab-4"]
            for step in 0..<3 {
                if step > 0 {
                    app.menuBars.menuBarItems["View"].click()
                    app.menuItems["Zoom In"].click()
                }
                let create = app.buttons["newWorkflow"]
                let browser = app.buttons["newBrowserTab"]
                let aligned = expectation(
                    for: NSPredicate { _, _ in
                        abs(create.frame.height - tab.frame.height) <= 1
                            && abs(browser.frame.height - tab.frame.height) <= 1
                            && abs(create.frame.midY - tab.frame.midY) <= 1
                            && abs(browser.frame.midY - tab.frame.midY) <= 1
                    }, evaluatedWith: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [aligned], timeout: 5), .completed, app.debugDescription)
                XCTAssertGreaterThanOrEqual(create.frame.minX, tab.frame.maxX)
                XCTAssertLessThan(create.frame.minX - tab.frame.maxX, 20)
                XCTAssertGreaterThanOrEqual(browser.frame.minX, create.frame.maxX)
                XCTAssertLessThan(browser.frame.minX - create.frame.maxX, 20)
                attachScreenshot(
                    of: app, named: "\(appearance), \(scrollBars) scrollbars, tab controls at zoom step \(step)")
            }
            app.terminate()
        }
    }

    @MainActor
    func testManagedTabsKeepCreateButtonBesideTabsAndReachableDuringOverflow() throws {
        let folder = try makeTestFolder(prefix: "HandshakeTabCreatePosition")
        let app = try managedTabApp(folder: folder)
        app.launchArguments += ["-AppleShowScrollBars", "Always"]
        app.launch()
        defer { app.terminate() }
        let first = app.buttons["workflowTab-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1200, height: 800))
        let create = app.buttons["newWorkflow"]
        let switcherWidth = app.buttons["tabSwitcher"].frame.width
        XCTAssertGreaterThanOrEqual(create.frame.minX, first.frame.maxX)
        XCTAssertLessThan(create.frame.minX - first.frame.maxX, 20)
        for id in 2...9 {
            XCTAssertTrue(create.isHittable, app.debugDescription)
            create.click()
            let tab = app.buttons["workflowTab-\(id)"]
            XCTAssertTrue(tab.waitForExistence(timeout: 5))
            waitForTab(tab, valueContaining: "Selected", in: app)
        }
        let last = app.buttons["workflowTab-9"]
        XCTAssertTrue(last.isHittable, app.debugDescription)
        XCTAssertTrue(create.isHittable, app.debugDescription)
        XCTAssertGreaterThanOrEqual(app.buttons["tabSwitcher"].frame.width, switcherWidth - 1)
        XCTAssertGreaterThanOrEqual(create.frame.minX, last.frame.maxX - 1)
        attachScreenshot(of: app, named: "Create button remains reachable with overflowing tabs")
        app.typeKey("1", modifierFlags: .command)
        waitForTab(first, valueContaining: "Selected", in: app)
        XCTAssertTrue(first.isHittable, app.debugDescription)
        XCTAssertTrue(create.isHittable, app.debugDescription)
        app.typeKey("w", modifierFlags: [.command, .shift])
        XCTAssertTrue(first.waitForNonExistence(timeout: 5))
        for _ in 0..<7 { app.typeKey("w", modifierFlags: [.command, .shift]) }
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        waitForTab(last, valueContaining: "Selected", in: app)
        XCTAssertGreaterThanOrEqual(create.frame.minX, last.frame.maxX)
        XCTAssertLessThan(create.frame.minX - last.frame.maxX, 20)
        attachScreenshot(of: app, named: "Create button follows the last remaining tab")
    }

    @MainActor
    func testManagedTabsValidateCancelAndResetNamesAndHandleEmptySearch() throws {
        let folder = try makeTestFolder(prefix: "HandshakeTabNames")
        let app = try managedTabApp(folder: folder)
        app.launch()
        defer { app.terminate() }
        let tab = app.buttons["workflowTab-1"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        let automaticName = tab.label
        app.typeKey("i", modifierFlags: [.command, .shift])
        let name = app.textFields["tabName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeKey("a", modifierFlags: .command)
        name.typeText("   ")
        XCTAssertFalse(app.sheets.buttons["Rename"].isEnabled)
        name.typeKey("a", modifierFlags: .command)
        name.typeText("API review")
        name.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))
        XCTAssertEqual(tab.label, "API review")
        app.typeKey("i", modifierFlags: [.command, .shift])
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeKey("a", modifierFlags: .command)
        name.typeText("Discard this title")
        name.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))
        XCTAssertEqual(tab.label, "API review")
        tab.rightClick()
        let reset = app.menuItems["Reset Name"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        XCTAssertTrue(reset.isEnabled)
        reset.click()
        let restored = expectation(for: NSPredicate { _, _ in tab.label == automaticName }, evaluatedWith: nil)
        wait(for: [restored], timeout: 5)
        app.typeKey("a", modifierFlags: [.command, .shift])
        let search = app.textFields["tabSwitcherSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("no-such-open-tab-zz")
        XCTAssertTrue(app.staticTexts["No matching tabs"].waitForExistence(timeout: 5))
        search.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(search.exists)
        search.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
        waitForTab(tab, valueContaining: "Selected", in: app)
        app.typeText("echo focused > after-empty-search\r")
        waitForFile(folder.appending(path: "after-empty-search"), containing: "focused", in: app)
    }

    @MainActor
    func testManagedTabsHideTopLevelRunningAndExitIndicators() throws {
        let folder = try makeTestFolder(prefix: "HandshakeTabUnread")
        let bin = folder.appending(path: "bin")
        try """
        case "$1" in --help|--list-models) exit 0 ;; esac
        echo $$ > agent.pid
        while [ ! -f finish-agent ]; do sleep 0.1; done
        """.write(to: folder.appending(path: "stub.txt"), atomically: true, encoding: .utf8)
        let app = try managedTabApp(folder: folder)
        app.launchEnvironment["HANDSHAKE_HARNESS_PATH"] = "\(bin.path):/bin:/usr/bin"
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
        let agent = app.buttons["workflowTab-2"]
        XCTAssertTrue(agent.waitForExistence(timeout: 5))
        chooseHarness("pi", in: app)
        let processID = try writtenProcessID(in: folder.appending(path: "agent.pid"), app: app)
        defer { endProcessIfRunning(processID) }
        XCTAssertFalse((agent.value as? String ?? "").contains("Running"))
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(app.buttons["workflowTab-3"].waitForExistence(timeout: 5))
        app.buttons["workflowChoice-Terminal"].click()
        app.typeText("touch finish-agent\r")
        let exited = expectation(for: NSPredicate { _, _ in kill(processID, 0) != 0 }, evaluatedWith: nil)
        wait(for: [exited], timeout: 10)
        XCTAssertFalse((agent.value as? String ?? "").contains("Exited"))
        XCTAssertFalse((agent.value as? String ?? "").contains("Unseen update"))
        waitForTab(app.buttons["workflowTab-3"], valueContaining: "Selected", in: app)
        attachScreenshot(of: app, named: "Top-level tab omits running and exit indicators")
        agent.click()
        waitForTab(agent, valueContaining: "Selected", in: app)
        let read = expectation(
            for: NSPredicate { _, _ in !(agent.value as? String ?? "").contains("Unseen update") }, evaluatedWith: nil)
        wait(for: [read], timeout: 5)
    }

    @MainActor
    func testManagedFileTabsDisambiguateSearchPinAndReopen() throws {
        let folder = try makeTestFolder(prefix: "HandshakeTabFileNames")
        let server = folder.appending(path: "server")
        let client = folder.appending(path: "client")
        for directory in [server, client] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try directory.lastPathComponent.write(
                to: directory.appending(path: "main.txt"), atomically: true, encoding: .utf8)
        }
        let app = try managedTabApp(folder: folder)
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1200, height: 800))
        setSidebar(open: true, in: app)
        for directory in [server, client] {
            let row = fileRow(directory, in: app)
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.click()
            let file = fileRow(directory.appending(path: "main.txt"), in: app)
            XCTAssertTrue(file.waitForExistence(timeout: 5))
            file.click()
        }
        let serverTab = fileTab(server.appending(path: "main.txt"), in: app)
        let clientTab = fileTab(client.appending(path: "main.txt"), in: app)
        XCTAssertEqual(serverTab.label, "server/main.txt")
        XCTAssertEqual(clientTab.label, "client/main.txt")
        app.typeKey("a", modifierFlags: [.command, .shift])
        let search = app.textFields["tabSwitcherSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("server/main.txt")
        search.typeKey(.return, modifierFlags: [])
        waitForTab(serverTab, valueContaining: "Selected", in: app)
        app.typeKey("p", modifierFlags: [.command, .shift])
        waitForTab(serverTab, valueContaining: "Pinned", in: app)
        XCTAssertLessThan(serverTab.frame.minX, app.buttons["workflowTab-1"].frame.minX)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(serverTab.waitForNonExistence(timeout: 5))
        XCTAssertEqual(clientTab.label, "main.txt")
        app.typeKey("t", modifierFlags: [.command, .shift])
        XCTAssertTrue(serverTab.waitForExistence(timeout: 5))
        waitForTab(serverTab, valueContaining: "Selected", in: app)
        waitForTab(serverTab, valueContaining: "Pinned", in: app)
        XCTAssertEqual(serverTab.label, "server/main.txt")
        let text = app.textViews["fileText"]
        let loaded = expectation(for: NSPredicate { _, _ in text.value as? String == "server" }, evaluatedWith: nil)
        wait(for: [loaded], timeout: 5)
        attachScreenshot(of: app, named: "Pinned file tab with disambiguated titles")
    }
}
