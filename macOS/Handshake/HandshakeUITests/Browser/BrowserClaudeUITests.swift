import XCTest

extension HandshakeUITests {
    /// Opt in locally with HANDSHAKE_LIVE_CLAUDE pointing to an authenticated Claude executable.
    @MainActor
    func testBrowserClaudeMCPControlsNativePage() async throws {
        guard let claude = ProcessInfo.processInfo.environment["HANDSHAKE_LIVE_CLAUDE"] else {
            throw XCTSkip("Set HANDSHAKE_LIVE_CLAUDE to run the authenticated integration test")
        }
        let folder = try makeTestFolder(prefix: "HandshakeBrowserClaude")
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
        let values = try JSONSerialization.data(withJSONObject: ["claude": claude, "prompt": prompt])
        try values.write(to: folder.appending(path: "live-input.json"))
        try writeLiveClaudeDriver(folder: folder)
        app.typeText("/usr/bin/python3 live-claude.py\r")
        let deadline = Date().addingTimeInterval(160)
        let done = folder.appending(path: "live-claude.done")
        while !FileManager.default.fileExists(atPath: done.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertEqual(try String(contentsOf: done, encoding: .utf8), "0")
        let log = try String(contentsOf: folder.appending(path: "live-claude.jsonl"), encoding: .utf8)
        XCTAssertTrue(log.contains("mcp__handshake_browser_test__browser"))
        XCTAssertTrue(log.contains("handshake_browser_test"))
        let summary =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: folder.appending(path: "live-summary.json"))) as? [String: Any]
        XCTAssertEqual(summary?["screenshot"] as? Bool, true)
        XCTAssertEqual(summary?["otherTools"] as? [String], [])
        XCTAssertEqual(summary?["toolErrors"] as? Int, 0)
        let note = app.webViews.textFields["Page note"]
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        XCTAssertEqual(note.value as? String, "MCP worked")
        attachScreenshot(of: app, named: "Real Claude browser MCP with scoped tool approval")
    }

    private func writeLiveClaudeDriver(folder: URL) throws {
        try """
        import json, os, subprocess
        with open('live-input.json') as stream:
            values = json.load(stream)
        name = 'mcp__handshake_browser_test__browser'
        config = json.dumps({'mcpServers': {'handshake_browser_test': {
            'type': 'stdio', 'command': os.environ['HANDSHAKE_CLI'], 'args': ['browser', 'mcp'],
            'env': {'HANDSHAKE_BROWSER_SOCKET': '${HANDSHAKE_BROWSER_SOCKET}',
                    'HANDSHAKE_BROWSER_TOKEN': '${HANDSHAKE_BROWSER_TOKEN}'}}}})
        with open('live-claude.jsonl', 'w') as output, open('live-claude.stderr', 'w') as errors:
            try:
                result = subprocess.run([values['claude'], '-p', '--permission-mode', 'default',
                    '--mcp-config', config, '--allowedTools', name,
                    '--output-format', 'stream-json', '--verbose', '--max-turns', '12',
                    '--no-session-persistence', '--', values['prompt']],
                    stdout=output, stderr=errors, timeout=150)
                code = result.returncode
            except subprocess.TimeoutExpired:
                code = 124
        summary = {'screenshot': False, 'otherTools': [], 'toolErrors': 0}
        with open('live-claude.jsonl') as stream:
            for line in stream:
                event = json.loads(line)
                for block in event.get('message', {}).get('content', []):
                    if not isinstance(block, dict):
                        continue
                    if block.get('type') == 'tool_use' and block.get('name') not in (name, 'ToolSearch'):
                        summary['otherTools'].append(block.get('name'))
                    if block.get('type') == 'tool_result':
                        summary['toolErrors'] += int(block.get('is_error', False))
                        content = block.get('content', [])
                        if isinstance(content, list):
                            summary['screenshot'] |= any(item.get('type') == 'image' for item in content)
        with open('live-summary.json', 'w') as stream:
            stream.write(json.dumps(summary))
        with open('live-claude.done', 'w') as done:
            done.write(str(code))
        """.write(to: folder.appending(path: "live-claude.py"), atomically: true, encoding: .utf8)
    }
}
