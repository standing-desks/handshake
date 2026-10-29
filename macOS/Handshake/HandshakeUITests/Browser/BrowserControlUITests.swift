import XCTest

extension HandshakeUITests {
    @MainActor
    func testBrowserCLIOpensLocalFilesWithoutLeavingTheTerminal() async throws {
        let folder = try makeTestFolder(prefix: "HandshakeLocalBrowser")
        let page = folder.appending(path: "my page #1.html")
        try "document.title='Local assets loaded';document.body.textContent='Local script works';".write(
            to: folder.appending(path: "asset.js"), atomically: true, encoding: .utf8)
        // Run after the body exists so the fixture verifies a real sibling resource load.
        try "<title>Local page</title><body><script src='asset.js'></script></body>".write(
            to: page, atomically: true, encoding: .utf8)
        let app = try managedTabApp(folder: folder)
        let config = folder.appending(path: "browser-config.toml")
        try "[experimental]\nbrowser_control = true\n".write(to: config, atomically: true, encoding: .utf8)
        app.launchEnvironment["HANDSHAKE_CONFIG_PATH"] = config.path
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
        let cli = try BrowserCLIProbe(directory: folder)
        app.typeText("sh browser-driver.sh &\r")
        waitForFile(folder.appending(path: "browser-ready"), containing: "ready", in: app)
        let opened = try await cli.run(["open", "my page #1.html"])
        let tab = try XCTUnwrap(opened["tab"] as? String)
        _ = try await cli.run(["--tab", tab, "wait", "Local script works"])
        _ = try await cli.run(["--tab", tab, "snapshot"])
        _ = try await cli.run(["--tab", tab, "navigate", page.absoluteString])
        _ = try await cli.run(["--tab", tab, "wait-load"])
        XCTAssertFalse(app.textFields["browserAddress"].exists)
        app.typeText("printf 'still in terminal' > keyboard-result\r")
        waitForFile(folder.appending(path: "keyboard-result"), containing: "still in terminal", in: app)
        _ = try await cli.run(["--tab", tab, "navigate", folder.appending(path: "missing.html").path], succeeds: false)
        _ = try await cli.run(["--tab", tab, "press", "ArrowDown"])
        XCTAssertTrue(app.textFields["browserAddress"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.webViews.staticTexts["Local script works"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testBrowserCLIControlsNativePageAndUserCanTakeOver() async throws {
        let folder = try makeTestFolder(prefix: "HandshakeBrowserControl")
        let server = try BrowserFixtureServer(root: folder.appending(path: "site"))
        try await server.start()
        defer { server.stop() }
        try writeBrowserControlFixture(to: server.root)
        let app = try managedTabApp(folder: folder)
        let config = folder.appending(path: "browser-config.toml")
        try "[experimental]\nbrowser_control = true\n".write(to: config, atomically: true, encoding: .utf8)
        app.launchEnvironment["HANDSHAKE_CONFIG_PATH"] = config.path
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
        let cli = try BrowserCLIProbe(directory: folder)
        app.typeText("sh browser-driver.sh\r")
        waitForFile(folder.appending(path: "browser-ready"), containing: "ready", in: app)
        let opened = try await cli.run(["open", server.url("control.html").absoluteString])
        let tab = try XCTUnwrap(opened["tab"] as? String)
        try await verifyBrowserActions(cli, opened: opened, tab: tab, server: server, app: app)
        try await verifyClosingPendingTab(cli, server: server, app: app)
        _ = try await cli.run(["--tab", tab, "snapshot"])
        app.buttons["browserTab-\(tab.uppercased())"].click()
        let pending = try cli.start(["--tab", tab, "wait", "never appears"])
        try await Task.sleep(for: .milliseconds(200))
        app.buttons["browserStopControl"].click()
        let cancelled = try await cli.finish(pending)
        XCTAssertEqual((cancelled["error"] as? [String: Any])?["code"] as? String, "cancelled")
        _ = try await cli.run(["--tab", tab, "snapshot"], succeeds: false)
        XCTAssertTrue(app.buttons["browserStopControl"].waitForNonExistence(timeout: 5))
        let note = app.webViews.textFields["Page note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.click()
        note.typeText("User took over")
        XCTAssertEqual(note.value as? String, "User took over")
        attachScreenshot(of: app, named: "Browser CLI controlled page and user takeover")
    }

    @MainActor
    private func verifyClosingPendingTab(
        _ cli: BrowserCLIProbe, server: BrowserFixtureServer, app: XCUIApplication
    ) async throws {
        let other = try await cli.run(["open", server.url("a").absoluteString])
        let otherID = try XCTUnwrap(other["tab"] as? String)
        let pending = try cli.start(["--tab", otherID, "wait", "never appears"])
        try await Task.sleep(for: .milliseconds(200))
        app.buttons["browserTab-\(otherID.uppercased())"].click()
        app.typeKey("w", modifierFlags: .command)
        let cancelled = try await cli.finish(pending)
        XCTAssertEqual((cancelled["error"] as? [String: Any])?["code"] as? String, "cancelled")
        _ = try await cli.run(["--tab", otherID, "snapshot"], succeeds: false)
    }

    @MainActor
    private func verifyBrowserActions(
        _ cli: BrowserCLIProbe, opened: [String: Any], tab: String, server: BrowserFixtureServer, app: XCUIApplication
    ) async throws {
        let snapshot = try BrowserCLIProbe.snapshot(opened)
        let elements = try XCTUnwrap(snapshot["elements"] as? [[String: Any]])
        let input = try XCTUnwrap(elements.first { $0["name"] as? String == "Name" }?["ref"] as? String)
        let button = try XCTUnwrap(elements.first { $0["name"] as? String == "Save" }?["ref"] as? String)
        _ = try await cli.run(["--tab", tab, "fill", input, "From the agent"])
        XCTAssertTrue(app.buttons["browserStopControl"].waitForExistence(timeout: 5))
        _ = try await cli.run(["--tab", tab, "press", "ArrowLeft"])
        _ = try await cli.run(["--tab", tab, "wait", "key:ArrowLeft:true"])
        _ = try await cli.run(["--tab", tab, "click", button])
        _ = try await cli.run(["--tab", tab, "wait", "From the agent:true:true"])
        let console = try await cli.run(["--tab", tab, "console"])
        XCTAssertTrue((console["content"] as? String ?? "").contains("saved fixture"))
        let screenshot = try await cli.run(["--tab", tab, "screenshot"])
        let png = try XCTUnwrap(screenshot["png"] as? String)
        XCTAssertEqual(Data(base64Encoded: png)?.prefix(4), Data([137, 80, 78, 71]))
        _ = try await cli.run(["--tab", tab, "scroll", "500"])
        _ = try await cli.run(["--tab", tab, "navigate", server.url("b").absoluteString])
        _ = try await cli.run(["--tab", tab, "click", button], succeeds: false)
    }

    private func writeBrowserControlFixture(to root: URL) throws {
        try """
        <!doctype html><title>Agent browser fixture</title>
        <style>body{font:18px system-ui;padding:30px}input,button{padding:12px;margin:12px}</style>
        <input id="note" aria-label="Name"><button id="save">Save</button><p id="result" role="status"></p>
        <script>
        let typed=false;
        note.addEventListener('input', e => typed=e.isTrusted);
        note.addEventListener('keydown', e => result.textContent='key:'+e.key+':'+e.isTrusted);
        save.addEventListener('click', e => {
            result.textContent=note.value+':'+typed+':'+e.isTrusted;
            console.log('saved fixture');
        });
        </script><div style="height:2000px">Scrollable page</div>
        """.write(to: root.appending(path: "control.html"), atomically: true, encoding: .utf8)
    }
}
