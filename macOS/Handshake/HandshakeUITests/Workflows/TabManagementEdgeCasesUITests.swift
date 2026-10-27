import XCTest

extension HandshakeUITests {
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
    func testManagedTabsMarkInactiveAgentExitUnreadUntilSelected() throws {
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
        waitForTab(agent, valueContaining: "Running", in: app)
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(app.buttons["workflowTab-3"].waitForExistence(timeout: 5))
        app.buttons["workflowChoice-Terminal"].click()
        app.typeText("touch finish-agent\r")
        waitForTab(agent, valueContaining: "Exited", in: app)
        waitForTab(agent, valueContaining: "Unseen update", in: app)
        waitForTab(app.buttons["workflowTab-3"], valueContaining: "Selected", in: app)
        attachScreenshot(of: app, named: "Inactive agent exit with unread tab indicator")
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
