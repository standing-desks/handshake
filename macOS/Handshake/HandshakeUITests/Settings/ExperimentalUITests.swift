import XCTest

extension HandshakeUITests {
    @MainActor
    func testExperimentalSettingsMigrateLegacyImportsOnceAndPreserveOptIn() throws {
        let fixture = try makeAMISFixture(featureEnabled: true)
        let app = fixture.app
        let config = URL(filePath: try XCTUnwrap(app.launchEnvironment["HANDSHAKE_CONFIG_PATH"]))
        let imported = config.deletingLastPathComponent().appending(path: "experimental-import.toml")
        try "# retained opt-in\n[feature_flags]\ncross_agent_memory_consolidation = true # keep\n".write(
            to: imported, atomically: true, encoding: .utf8)
        try "import = 'experimental-import.toml'\n[feature_flags]\ntab_management = false\n".write(
            to: config, atomically: true, encoding: .utf8)
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        setSidebar(open: true, in: app)
        XCTAssertTrue(app.buttons["openNativeMemory"].waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)
        let section = app.sheets.radioButtons["Experimental"]
        XCTAssertTrue(section.waitForExistence(timeout: 10))
        section.click()
        let toggle = memoryFeatureToggle(in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertTrue((toggle.value as? NSNumber)?.boolValue == true || toggle.value as? String == "1")
        let migrated = try String(contentsOf: config, encoding: .utf8)
        let migratedImport = try String(contentsOf: imported, encoding: .utf8)
        XCTAssertEqual(migrated, "import = 'experimental-import.toml'\n[experimental]\ntab_management = false\n")
        XCTAssertEqual(
            migratedImport, "# retained opt-in\n[experimental]\ncross_agent_memory_consolidation = true # keep\n")
        let modification = try imported.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        app.buttons["closeSettings"].click()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), migrated)
        XCTAssertEqual(try String(contentsOf: imported, encoding: .utf8), migratedImport)
        XCTAssertEqual(
            try imported.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modification)
    }

    @MainActor
    func testExperimentalFeatureControlsMemorySharingImmediatelyAndPersists() throws {
        let fixture = try makeAMISFixture(featureEnabled: false)
        let app = fixture.app
        let config = URL(filePath: try XCTUnwrap(app.launchEnvironment["HANDSHAKE_CONFIG_PATH"]))
        let initial = try String(contentsOf: config, encoding: .utf8)
        try initial.replacingOccurrences(of: "cross_agent_memory_consolidation = false", with: "")
            .write(to: config, atomically: true, encoding: .utf8)
        app.launch()
        setSidebar(open: true, in: app)
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["openNativeMemory"].exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.path))
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
        try verifyRawSettingsRefreshTheExperimentalFeature(in: app)
    }

    @MainActor
    func testExperimentalFeatureProtectsUnsavedConfiguration() throws {
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
        app.sheets.radioButtons["Experimental"].click()
        let toggle = memoryFeatureToggle(in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertFalse(toggle.isEnabled)
        XCTAssertTrue(app.staticTexts["experimentalUnsavedConfiguration"].exists)
        attachScreenshot(of: app, named: "Experimental protect the unsaved configuration buffer")
    }

    @MainActor
    private func setMemoryFeature(_ value: Bool, in app: XCUIApplication, config: URL) throws {
        app.typeKey(",", modifierFlags: .command)
        let section = app.sheets.radioButtons["Experimental"]
        XCTAssertTrue(section.waitForExistence(timeout: 10), app.debugDescription)
        section.click()
        let toggle = memoryFeatureToggle(in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(toggle.label.contains("Beta"), app.debugDescription)
        XCTAssertFalse(
            app.descendants(matching: .any).matching(identifier: "experimentalFeature-tabManagement").firstMatch.exists)
        toggle.click()
        waitForFile(config, containing: "cross_agent_memory_consolidation = \(value)", in: app)
        let settled = expectation(
            for: NSPredicate { _, _ in toggle.isEnabled }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 15), .completed, app.debugDescription)
        XCTAssertFalse(app.staticTexts["experimentalFailure"].exists, app.debugDescription)
        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(text.contains("[experimental]"))
        XCTAssertFalse(text.contains("[feature_flags]"))
        XCTAssertTrue(text.contains("font_size = 14 # keep this"))
        attachScreenshot(of: app, named: "Cross-agent memory experimental feature — \(value ? "enabled" : "disabled")")
        app.buttons["closeSettings"].click()
    }

    @MainActor
    private func verifyRawSettingsRefreshTheExperimentalFeature(in app: XCUIApplication) throws {
        app.typeKey(",", modifierFlags: .command)
        let text = app.sheets.textViews["fileText"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        let current = try XCTUnwrap(text.value as? String)
        text.click()
        text.typeKey("a", modifierFlags: .command)
        text.typeText(
            current.replacingOccurrences(of: "[experimental]", with: "[feature_flags]").replacingOccurrences(
                of: "cross_agent_memory_consolidation = false", with: "cross_agent_memory_consolidation = true"))
        app.typeKey("s", modifierFlags: .command)
        waitForSave(in: app)
        let migrated = expectation(
            for: NSPredicate { _, _ in (text.value as? String)?.contains("[experimental]") == true },
            evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [migrated], timeout: 10), .completed, app.debugDescription)
        app.sheets.radioButtons["Experimental"].click()
        let toggle = memoryFeatureToggle(in: app)
        let enabledExpectation = expectation(
            for: NSPredicate { _, _ in
                (toggle.value as? NSNumber)?.boolValue == true || toggle.value as? String == "1"
            }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [enabledExpectation], timeout: 10), .completed, app.debugDescription)
        XCTAssertFalse(app.staticTexts["experimentalFailure"].exists)
        app.buttons["closeSettings"].click()
        XCTAssertTrue(app.buttons["openNativeMemory"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func memoryFeatureToggle(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "experimentalFeature-crossAgentMemoryConsolidation")
            .firstMatch
    }
}
