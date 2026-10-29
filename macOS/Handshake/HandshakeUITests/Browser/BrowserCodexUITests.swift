import XCTest

extension HandshakeUITests {
    /// Opt in locally with HANDSHAKE_LIVE_CODEX pointing to an authenticated Codex executable.
    @MainActor
    func testBrowserCodexMCPWorksWithNormalSandbox() async throws {
        guard let codex = ProcessInfo.processInfo.environment["HANDSHAKE_LIVE_CODEX"] else {
            throw XCTSkip("Set HANDSHAKE_LIVE_CODEX to run the authenticated integration test")
        }
        let folder = try makeTestFolder(prefix: "HandshakeBrowserCodex")
        let server = try BrowserFixtureServer(root: folder.appending(path: "site"))
        try await server.start()
        defer { server.stop() }
        let app = try managedTabApp(folder: folder)
        let config = folder.appending(path: "browser-config.toml")
        try "[experimental]\nbrowser_control = true\n".write(to: config, atomically: true, encoding: .utf8)
        app.launchEnvironment["HANDSHAKE_CONFIG_PATH"] = config.path
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
        let url = try server.url("a")
        let prompt = """
            Use only the handshake_browser_test browser MCP tool for this task. Open \(url),
            fill Page note with MCP worked, take a screenshot, and finish. Use snapshot references.
            Do not use shell commands, external browsers, or change any permissions.
            """
        let values = try JSONSerialization.data(withJSONObject: ["codex": codex, "prompt": prompt])
        try values.write(to: folder.appending(path: "live-input.json"))
        try writeLiveCodexDriver(folder: folder)
        app.typeText("/usr/bin/python3 live-codex.py\r")
        let deadline = Date().addingTimeInterval(160)
        let done = folder.appending(path: "live-codex.done")
        while !FileManager.default.fileExists(atPath: done.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertEqual(try String(contentsOf: done, encoding: .utf8), "0")
        let log = try String(contentsOf: folder.appending(path: "live-codex.jsonl"), encoding: .utf8)
        XCTAssertTrue(log.contains("mcp_tool_call"))
        XCTAssertTrue(log.contains("handshake_browser_test"))
        XCTAssertFalse(log.contains("command_execution"))
        let note = app.webViews.textFields["Page note"]
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        XCTAssertEqual(note.value as? String, "MCP worked")
        attachScreenshot(of: app, named: "Real Codex browser MCP with workspace sandbox")
    }

    private func writeLiveCodexDriver(folder: URL) throws {
        try """
        import json, os, subprocess
        with open('live-input.json') as stream:
            values = json.load(stream)
        config = 'mcp_servers.handshake_browser_test={' + ','.join([
            'command=' + json.dumps(os.environ['HANDSHAKE_CLI']),
            'args=["browser","mcp"]',
            'env_vars=["HANDSHAKE_BROWSER_SOCKET","HANDSHAKE_BROWSER_TOKEN"]',
            'tool_timeout_sec=35']) + '}'
        with open('live-codex.jsonl', 'w') as output, open('live-codex.stderr', 'w') as errors:
            try:
                result = subprocess.run([values['codex'], 'exec', '--skip-git-repo-check',
                    '--approve-for-me',
                    '-c', config, '--json', values['prompt']], stdout=output, stderr=errors, timeout=150)
                code = result.returncode
            except subprocess.TimeoutExpired:
                code = 124
        with open('live-codex.done', 'w') as done:
            done.write(str(code))
        """.write(to: folder.appending(path: "live-codex.py"), atomically: true, encoding: .utf8)
    }
}
