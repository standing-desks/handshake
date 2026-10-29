import XCTest

extension HandshakeUITests {
    @MainActor
    func testBrowserControlFlagGatesAgentInstructionsAndRevokesLiveCommands() async throws {
        try await verifyBrowserControlFlag(claude: false)
    }

    @MainActor
    func testBrowserControlFlagGatesClaudeMCPAndRevokesLiveCommands() async throws {
        try await verifyBrowserControlFlag(claude: true)
    }

    @MainActor
    private func verifyBrowserControlFlag(claude: Bool) async throws {
        let binary = claude ? "claude" : "codex"
        let harness = claude ? "claudeCode" : "codex"
        let displayName = claude ? "Claude Code" : "Codex"
        let folder = try makeTestFolder(prefix: "HandshakeBrowserFlag")
        let server = try BrowserFixtureServer(root: folder.appending(path: "site"))
        try await server.start()
        defer { server.stop() }
        let cli = try BrowserCLIProbe(directory: folder)
        let config = folder.appending(path: "config.toml")
        try "# Browser control defaults off\n".write(to: config, atomically: true, encoding: .utf8)
        let app = try browserInstructionApp(folder: folder, config: config)
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
        app.typeText("mkdir bin; cat codex-fixture > bin/\(binary); chmod +x bin/\(binary); echo ready > installed\r")
        waitForFile(folder.appending(path: "installed"), containing: "ready", in: app)
        app.buttons["newWorkflow"].click()
        chooseHarness(harness, displayName: displayName, in: app)
        waitForFile(folder.appending(path: "browser-disabled"), containing: "no credentials", in: app)
        let disabledArgs = try String(contentsOf: folder.appending(path: "agent-arguments"), encoding: .utf8)
        XCTAssertFalse(disabledArgs.contains("Handshake embedded browser"))
        XCTAssertFalse(disabledArgs.contains("handshake_browser_"))
        XCTAssertFalse(disabledArgs.contains("--mcp-config"))
        try setBrowserControlFlag(true, in: app, config: config)
        app.buttons["newWorkflow"].click()
        chooseHarness(harness, displayName: displayName, in: app)
        waitForFile(folder.appending(path: "browser-ready"), containing: "ready", in: app)
        let args = try String(contentsOf: folder.appending(path: "agent-arguments"), encoding: .utf8)
        verifyBrowserArguments(args, claude: claude)
        let opened = try await cli.run(["open", server.url("a").absoluteString])
        let tab = try XCTUnwrap(opened["tab"] as? String)
        let pending = try cli.start(["--tab", tab, "wait", "never appears"])
        try await Task.sleep(for: .milliseconds(200))
        try setBrowserControlFlag(false, in: app, config: config)
        let cancelled = try await cli.finish(pending)
        XCTAssertEqual((cancelled["error"] as? [String: Any])?["code"] as? String, "cancelled")
        let disabled = try await cli.run(["list"], succeeds: false)
        XCTAssertEqual((disabled["error"] as? [String: Any])?["code"] as? String, "feature_disabled")
        XCTAssertTrue(app.buttons["browserStopControl"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.webViews.textFields["Page note"].exists)
        try setBrowserControlFlag(true, in: app, config: config)
        let revoked = try await cli.run(["list"], succeeds: false)
        XCTAssertEqual((revoked["error"] as? [String: Any])?["code"] as? String, "unauthorized")
        try setBrowserControlFlag(false, in: app, config: config)
        attachScreenshot(of: app, named: "Browser control disabled while the page stays open")
    }

    private func verifyBrowserArguments(_ args: String, claude: Bool) {
        XCTAssertTrue(args.contains(claude ? "--append-system-prompt" : "developer_instructions="))
        XCTAssertTrue(args.contains("Handshake embedded browser"))
        if !claude { XCTAssertTrue(args.contains("Existing fixture instructions")) }
        XCTAssertTrue(args.contains("handshake_browser_"))
        if claude { XCTAssertTrue(args.contains("--mcp-config")) }
        XCTAssertTrue(args.contains("HANDSHAKE_BROWSER_TOKEN"))
        XCTAssertFalse(args.contains("dangerously-bypass"))
        XCTAssertFalse(args.contains("sandbox_mode="))
        XCTAssertFalse(args.contains("--dangerously-skip-permissions"))
        XCTAssertFalse(args.contains("--allowedTools"))
        XCTAssertFalse(args.contains("--strict-mcp-config"))
    }

    @MainActor
    private func setBrowserControlFlag(_ enabled: Bool, in app: XCUIApplication, config: URL) throws {
        app.typeKey(",", modifierFlags: .command)
        let section = app.sheets.radioButtons["Experimental"]
        XCTAssertTrue(section.waitForExistence(timeout: 10))
        section.click()
        let toggle = app.descendants(matching: .any).matching(identifier: "experimentalFeature-browserControl")
            .firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertTrue(toggle.label.contains("Beta"))
        toggle.click()
        waitForFile(config, containing: "browser_control = \(enabled)", in: app)
        let settled = expectation(for: NSPredicate { _, _ in toggle.isEnabled }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 15), .completed)
        XCTAssertFalse(app.staticTexts["experimentalFailure"].exists)
        app.buttons["closeSettings"].click()
    }

    @MainActor
    private func browserInstructionApp(folder: URL, config: URL) throws -> XCUIApplication {
        try """
        #!/bin/sh
        case "$1" in
          --help|--version) exit 0 ;;
          debug)
            printf '%s\\n' '{"models":[{"slug":"fixture-model","display_name":"Fixture","visibility":"list"}]}'
            exit ;;
          app-server)
            read -r line
            printf '%s\\n' '{"id":1,"result":{}}'
            read -r line
            read -r line
            printf '%s\\n' '{"id":2,"result":{"config":{"developer_instructions":"Existing fixture instructions"}}}'
            exit ;;
        esac
        printf '%s\\n' "$@" > agent-arguments
        if [ -z "$HANDSHAKE_BROWSER_TOKEN" ]; then
            printf 'no credentials' > browser-disabled
            while :; do sleep 1; done
        fi
        exec sh browser-driver.sh
        """.write(to: folder.appending(path: "codex-fixture"), atomically: true, encoding: .utf8)
        let app = try managedTabApp(folder: folder)
        app.launchEnvironment["HANDSHAKE_CONFIG_PATH"] = config.path
        app.launchEnvironment["HANDSHAKE_HARNESS_PATH"] = "\(folder.path)/bin:/bin:/usr/bin"
        return app
    }
}
