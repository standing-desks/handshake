import XCTest

extension HandshakeUITests {
    @MainActor
    func testBrowserCLINestedDocumentsAndRichInteractions() async throws {
        let folder = try makeTestFolder(prefix: "HandshakeBrowserInteractions")
        let server = try BrowserFixtureServer(root: folder.appending(path: "site"))
        try BrowserInteractionFixture.html.write(
            to: server.root.appending(path: "interactions.html"), atomically: true, encoding: .utf8)
        try await server.start()
        defer { server.stop() }
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
        let opened = try await cli.run(["open", server.url("interactions.html").absoluteString])
        let tab = try XCTUnwrap(opened["tab"] as? String)
        _ = try await cli.run(["--tab", tab, "wait", "Frame ready"])
        _ = try await cli.run(["--tab", tab, "wait-url", "interactions.html"])
        _ = try await cli.run(["--tab", tab, "wait-load"])
        let snapshot = try BrowserCLIProbe.snapshot(try await cli.run(["--tab", tab, "snapshot"]))
        let elements = try XCTUnwrap(snapshot["elements"] as? [[String: Any]])
        func ref(_ name: String) throws -> String {
            try XCTUnwrap(elements.first { $0["name"] as? String == name }?["ref"] as? String)
        }
        _ = try await cli.run(["--tab", tab, "select", try ref("Plan"), "pro"])
        _ = try await cli.run(["--tab", tab, "wait", "plan:pro:true"])
        _ = try await cli.run(["--tab", tab, "hover", try ref("Hover me")])
        _ = try await cli.run(["--tab", tab, "wait", "hover:true"])
        _ = try await cli.run(["--tab", tab, "fill", try ref("Shadow note"), "draft"])
        _ = try await cli.run(["--tab", tab, "press", "Meta+Shift+ArrowLeft"])
        _ = try await cli.run(["--tab", tab, "press", "Shift+z"])
        _ = try await cli.run(["--tab", tab, "click", try ref("Save shadow")])
        _ = try await cli.run(["--tab", tab, "wait", "shadow:Z:true"])
        _ = try await cli.run(["--tab", tab, "wait-element", try ref("Frame note"), "enabled"])
        _ = try await cli.run(["--tab", tab, "fill", try ref("Frame note"), "Nested"])
        _ = try await cli.run(["--tab", tab, "click", try ref("Save frame")])
        _ = try await cli.run(["--tab", tab, "wait", "frame:Nested:true"])
        _ = try await cli.run(["--tab", tab, "press", "Meta+Shift+a"], succeeds: false)
        XCTAssertFalse(app.textFields["Find a tab"].exists)
        attachScreenshot(of: app, named: "Browser nested documents and trusted interactions")
    }
}
