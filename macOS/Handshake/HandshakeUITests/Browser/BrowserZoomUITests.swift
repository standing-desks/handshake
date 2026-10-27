import XCTest

extension HandshakeUITests {
    @MainActor
    func testBrowserZoomRetainsPageAndKeepsCornerLinksInteractive() async throws {
        let folder = try makeTestFolder(prefix: "HandshakeBrowserZoom")
        let site = folder.appending(path: "site")
        let server = try BrowserFixtureServer(root: site)
        try """
        <!doctype html><title>Zoom page</title><style>
        html,body{margin:0} #viewport{position:fixed;inset:0;background:#d6f5e8}
        h1{position:relative;margin:0;font:bold 24px sans-serif}
        #corner{position:fixed;right:12px;bottom:12px}
        </style><a id="viewport" aria-label="Browser viewport" href="#top"></a>
        <h1 id="top">Browser zoom</h1><a id="corner" href="/b">Browser corner</a>
        """.write(to: site.appending(path: "zoom"), atomically: true, encoding: .utf8)
        try await server.start()
        defer { server.stop() }
        for appearance in ["Light", "Dark"] {
            let app = try makeApp(lastOpenFolder: folder)
            app.launchEnvironment["HANDSHAKE_TEST_APPEARANCE"] = appearance
            app.launch()
            XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
            resizeWindow(app.windows.firstMatch, to: CGSize(width: 1100, height: 800))
            app.buttons["newBrowserTab"].click()
            navigateBrowser(to: try server.url("zoom"), in: app)
            let tab = browserTabs(in: app).firstMatch
            waitForBrowserTitle("Zoom page", tab: tab, in: app)
            let heading = app.webViews.staticTexts["Browser zoom"]
            XCTAssertTrue(heading.waitForExistence(timeout: 5))
            let height = heading.frame.height
            for (percent, steps) in [(50, -4), (100, 0), (125, 2), (200, 6)] {
                app.typeKey("0", modifierFlags: .command)
                for _ in 0..<abs(steps) { app.typeKey(steps < 0 ? "-" : "=", modifierFlags: .command) }
                assertBrowserZoom(percent, heading: heading, height: height, in: app)
                attachScreenshot(of: app, named: "Browser \(appearance) at \(percent) percent")
            }
            app.links["Browser corner"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            waitForBrowserTitle("Page B", tab: tab, in: app)
            app.typeKey("[", modifierFlags: .command)
            waitForBrowserTitle("Zoom page", tab: tab, in: app)
            app.terminate()
        }
    }

    @MainActor
    private func assertBrowserZoom(_ percent: Int, heading: XCUIElement, height: CGFloat, in app: XCUIApplication) {
        let viewport = app.links["Browser viewport"]
        let corner = app.links["Browser corner"]
        let scale = CGFloat(percent) / 100
        let resized = expectation(
            for: NSPredicate { _, _ in abs(heading.frame.height - height * scale) < 2 }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [resized], timeout: 5), .completed, app.debugDescription)
        XCTAssertEqual(corner.frame.maxX, viewport.frame.maxX - 12 * scale, accuracy: 2)
        XCTAssertEqual(corner.frame.maxY, viewport.frame.maxY - 12 * scale, accuracy: 2)
        XCTAssertTrue(app.buttons["newBrowserTab"].isHittable)
        XCTAssertTrue(app.textFields["browserAddress"].isHittable)
    }
}
