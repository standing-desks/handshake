import XCTest

extension HandshakeUITests {
    @MainActor
    func testFirstLaunchShowsStartPage() throws {
        let app = try makeApp()
        app.launch()

        XCTAssertTrue(app.staticTexts["Welcome to Handshake"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Open Folder…"].exists)
        XCTAssertTrue(app.staticTexts["Folders you open appear here."].exists)
        app.menuBars.menuBarItems["File"].click()
        XCTAssertTrue(app.menuItems["New Window"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testRelaunchOpensLastFolderAndReturnsToStartPage() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "HandshakeUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: folder)
        }
        let app = try makeApp(lastOpenFolder: folder)
        app.launch()

        let toggle = sidebarToggle(in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["Start Page"].exists)
        // The window's accessibility title also includes the subtitle, the folder's path.
        XCTAssertTrue(app.windows.firstMatch.title.hasPrefix(folder.lastPathComponent), app.debugDescription)
        XCTAssertFalse(app.staticTexts["Welcome to Handshake"].exists, app.debugDescription)

        // The reopened folder's terminal takes typing without a click.
        let marker = folder.appending(path: "typed-marker")
        app.typeText("touch \(marker.lastPathComponent)\r")
        let typed = expectation(
            for: NSPredicate { _, _ in FileManager.default.fileExists(atPath: marker.path) }, evaluatedWith: nil)
        wait(for: [typed], timeout: 10)

        closeFolder(in: app)
        XCTAssertTrue(app.staticTexts["Welcome to Handshake"].waitForExistence(timeout: 10), app.debugDescription)
        let recent = recentFolder(folder.lastPathComponent, in: app)
        XCTAssertTrue(recent.waitForExistence(timeout: 10), app.debugDescription)

        recent.click()
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), app.debugDescription)

        closeFolder(in: app)
        XCTAssertTrue(app.staticTexts["Welcome to Handshake"].waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor
    func testMissingLastFolderIsExplainedAndCanBeRemoved() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "HandshakeUITests-\(UUID().uuidString)")
        let app = try makeApp(lastOpenFolder: missing)
        app.launch()

        // macOS exposes a text's string as its accessibility value.
        let explanation = app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", "because it can't be found")
        ).firstMatch
        XCTAssertTrue(explanation.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(recentFolder(missing.lastPathComponent, in: app).exists, app.debugDescription)

        recentFolder(missing.lastPathComponent, in: app).hover()
        app.buttons["Remove from Recent Folders"].firstMatch.click()
        XCTAssertTrue(
            app.staticTexts["Folders you open appear here."].waitForExistence(timeout: 10),
            app.debugDescription
        )
        XCTAssertFalse(explanation.exists, app.debugDescription)
    }

    @MainActor
    private func recentFolder(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }
}
