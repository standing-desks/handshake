import XCTest

extension HandshakeUITests {
    @MainActor
    func testFeatureFlagControlsMemorySharingImmediatelyAndPersists() throws {
        let fixture = try makeAMISFixture(featureEnabled: false)
        let app = fixture.app
        app.launch()
        setSidebar(open: true, in: app)
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["openNativeMemory"].exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.path))
        let config = URL(filePath: try XCTUnwrap(app.launchEnvironment["HANDSHAKE_CONFIG_PATH"]))
        try setMemoryFeature(true, in: app, config: config)
        XCTAssertTrue(app.buttons["openNativeMemory"].waitForExistence(timeout: 10))
        openHandshakeMemory(in: app)
        waitForHandshakeText("1 project memories", identifier: "handshakeMemoryCount", in: app)
        app.typeKey(.escape, modifierFlags: [])
        try setMemoryFeature(false, in: app, config: config)
        XCTAssertTrue(app.buttons["openNativeMemory"].waitForNonExistence(timeout: 10))
        let project = try fixture.projectRoot()
        let library = project.appending(path: "library.amis.json")
        let before = try Data(contentsOf: library)
        try "# Saved while disabled\nUse a violet lane.\n".write(
            to: fixture.source.appending(path: "while-disabled.md"), atomically: true, encoding: .utf8)
        let noWrite = expectation(
            for: NSPredicate { _, _ in (try? Data(contentsOf: library)) != before }, evaluatedWith: nil)
        noWrite.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [noWrite], timeout: 6), .completed)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["openNativeMemory"].exists)
        XCTAssertEqual(try Data(contentsOf: library), before)
        try verifyRawSettingsRefreshTheFeatureFlag(in: app)
    }

    @MainActor
    func testFeatureFlagProtectsUnsavedConfiguration() throws {
        let fixture = try makeAMISFixture(featureEnabled: false)
        let app = fixture.app
        app.launch()
        defer { app.terminate() }
        app.typeKey(",", modifierFlags: .command)
        let text = app.sheets.textViews["fileText"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        text.click()
        text.typeKey("a", modifierFlags: .command)
        text.typeText("# Unsaved configuration\n")
        app.sheets.radioButtons["Feature flags"].click()
        let toggle = memoryFeatureToggle(in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertFalse(toggle.isEnabled)
        XCTAssertTrue(app.staticTexts["featureFlagsUnsavedConfiguration"].exists)
        attachScreenshot(of: app, named: "Feature flags protect the unsaved configuration buffer")
    }

    @MainActor
    private func setMemoryFeature(_ value: Bool, in app: XCUIApplication, config: URL) throws {
        app.typeKey(",", modifierFlags: .command)
        let section = app.sheets.radioButtons["Feature flags"]
        XCTAssertTrue(section.waitForExistence(timeout: 10), app.debugDescription)
        section.click()
        let toggle = memoryFeatureToggle(in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), app.debugDescription)
        toggle.click()
        waitForFile(config, containing: "cross_agent_memory_consolidation = \(value)", in: app)
        let settled = expectation(
            for: NSPredicate { _, _ in toggle.isEnabled }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 15), .completed, app.debugDescription)
        XCTAssertFalse(app.staticTexts["featureFlagsFailure"].exists, app.debugDescription)
        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(text.contains("font_size = 14 # keep this"))
        attachScreenshot(of: app, named: "Cross-agent memory feature flag — \(value ? "enabled" : "disabled")")
        app.buttons["closeSettings"].click()
    }

    @MainActor
    private func verifyRawSettingsRefreshTheFeatureFlag(in app: XCUIApplication) throws {
        app.typeKey(",", modifierFlags: .command)
        let text = app.sheets.textViews["fileText"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        let current = try XCTUnwrap(text.value as? String)
        text.click()
        text.typeKey("a", modifierFlags: .command)
        text.typeText(
            current.replacingOccurrences(
                of: "cross_agent_memory_consolidation = false", with: "cross_agent_memory_consolidation = true"))
        app.typeKey("s", modifierFlags: .command)
        waitForSave(in: app)
        app.sheets.radioButtons["Feature flags"].click()
        let toggle = memoryFeatureToggle(in: app)
        let enabledExpectation = expectation(
            for: NSPredicate { _, _ in
                (toggle.value as? NSNumber)?.boolValue == true || toggle.value as? String == "1"
            }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [enabledExpectation], timeout: 10), .completed, app.debugDescription)
        XCTAssertFalse(app.staticTexts["featureFlagsFailure"].exists)
    }

    @MainActor
    private func memoryFeatureToggle(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "featureFlag-crossAgentMemoryConsolidation").firstMatch
    }
}
