import AppKit
import XCTest

extension TwineUITests {
    @MainActor
    func testNativeMemoryEmptyStateAndReopen() throws {
        let fixture = try makeNativeMemoryFixture(hasMemories: false)
        let app = fixture.app
        app.launch()
        defer { app.terminate() }
        openNativeMemory(in: app)
        waitForNativeStatus("Import unavailable", in: app)
        XCTAssertFalse(app.buttons["importClaudeMemories"].isEnabled)
        XCTAssertTrue(
            staticTextValue(app.staticTexts["nativeMemoryImportMessage"]).contains("No native Claude memories"))
        XCTAssertFalse(app.staticTexts["nativeMemoryPath-Claude Code"].exists)
        attachScreenshot(of: app, named: "Native memory — empty state")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons["importClaudeMemories"].waitForNonExistence(timeout: 5))
        openNativeMemory(in: app)
        waitForNativeStatus("Import unavailable", in: app)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @MainActor
    func testNativeMemoryImportsWithRealCodexAndRefreshesAfterReopen() throws {
        let fixture = try makeNativeMemoryFixture()
        let app = fixture.app
        app.launch()
        defer { app.terminate() }
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 720, height: 620))
        openNativeMemory(in: app)
        waitForNativeStatus("Ready to import", in: app)
        let action = app.buttons["importClaudeMemories"]
        XCTAssertTrue(action.isEnabled && action.isHittable)
        XCTAssertFalse(app.staticTexts["nativeMemoryPath-Claude Code"].exists)
        attachScreenshot(of: app, named: "Native memory — ready at narrow window")
        let locations = app.buttons["nativeMemoryLocations"]
        XCTAssertTrue(locations.exists, app.debugDescription)
        locations.click()
        XCTAssertTrue(app.staticTexts["nativeMemoryPath-Claude Code"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["nativeMemoryPath-Codex"].exists)
        XCTAssertTrue(action.isHittable)
        attachScreenshot(of: app, named: "Native memory — optional native locations")
        locations.click()
        action.click()
        waitForNativeStatus("Submitted to Codex", in: app)
        XCTAssertFalse(action.isEnabled)
        XCTAssertTrue(
            staticTextValue(app.staticTexts["nativeMemoryImportMessage"]).localizedCaseInsensitiveContains(
                "consolidation"))
        XCTAssertEqual(
            try String(contentsOf: fixture.destination.appending(path: "customer.md"), encoding: .utf8), fixture.body)
        XCTAssertEqual(
            try String(contentsOf: fixture.source.appending(path: "customer.md"), encoding: .utf8), fixture.body)
        attachScreenshot(of: app, named: "Native memory — real import completed, consolidation pending")
        app.buttons["refreshNativeMemory"].click()
        waitForNativeStatus("No pending import", in: app)
        XCTAssertFalse(action.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(action.waitForNonExistence(timeout: 5))
        openNativeMemory(in: app)
        waitForNativeStatus("No pending import", in: app)
        XCTAssertFalse(action.isEnabled)
        attachScreenshot(of: app, named: "Native memory — reopened after import")
        try verifyNativeCleanup(fixture)
    }

    @MainActor
    private func verifyNativeCleanup(_ fixture: NativeMemoryImportFixture) throws {
        let app = fixture.app
        let action = app.buttons["importClaudeMemories"]
        try FileManager.default.removeItem(at: fixture.source.appending(path: "MEMORY.md"))
        try FileManager.default.removeItem(at: fixture.source.appending(path: "customer.md"))
        app.buttons["refreshNativeMemory"].click()
        waitForNativeStatus("Ready to remove imported memories", in: app)
        XCTAssertEqual(action.label, "Remove imported memories")
        XCTAssertTrue(action.isEnabled)
        attachScreenshot(of: app, named: "Native memory — explicit cleanup after source deletion")
        action.click()
        waitForNativeStatus("Submitted to Codex", in: app)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        app.buttons["refreshNativeMemory"].click()
        waitForNativeStatus("Import unavailable", in: app)
        XCTAssertFalse(action.isEnabled)
    }

    @MainActor
    func testNativeMemoryDisabledConfigurationRecoversOnRefresh() throws {
        let fixture = try makeNativeMemoryFixture(enabled: false)
        let app = fixture.app
        app.launch()
        defer { app.terminate() }
        openNativeMemory(in: app)
        waitForNativeStatus("Import unavailable", in: app)
        XCTAssertFalse(app.buttons["importClaudeMemories"].isEnabled)
        XCTAssertTrue(staticTextValue(app.staticTexts["nativeMemoryImportMessage"]).contains("disabled"))
        attachScreenshot(of: app, named: "Native memory — disabled configuration")
        try "[features]\nmemories = true\n".write(to: fixture.config, atomically: true, encoding: .utf8)
        app.buttons["refreshNativeMemory"].click()
        waitForNativeStatus("Ready to import", in: app)
        XCTAssertTrue(app.buttons["importClaudeMemories"].isEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        attachScreenshot(of: app, named: "Native memory — recovered by refresh")
    }

    @MainActor
    func testNativeMemoryLargeLibraryImportsAndUpdates() throws {
        let fixture = try makeNativeMemoryFixture()
        for index in 0..<1100 {
            try "# Synthetic topic \(index)\n\nFictional memory fixture \(index).\n".write(
                to: fixture.source.appending(path: "topic-\(index).md"), atomically: true, encoding: .utf8)
        }
        let app = fixture.app
        app.launch()
        defer { app.terminate() }
        openNativeMemory(in: app)
        waitForNativeStatus("Ready to import", in: app)
        XCTAssertEqual(staticTextValue(app.staticTexts["nativeMemorySourceCount"]).filter(\.isNumber), "1102")
        app.buttons["importClaudeMemories"].click()
        waitForNativeStatus("Submitted to Codex", in: app)
        let files = try FileManager.default.contentsOfDirectory(
            at: fixture.destination, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.filter { $0.pathExtension == "md" }.count, 1102)
        attachScreenshot(of: app, named: "Native memory — 1102 files imported with real Codex")
        let updated = "# Trial customer\n\nUse Juniper North and demo-juniper-42 for this fictional project.\n"
        try updated.write(to: fixture.source.appending(path: "customer.md"), atomically: true, encoding: .utf8)
        app.buttons["refreshNativeMemory"].click()
        waitForNativeStatus("Ready to import", in: app)
        app.buttons["importClaudeMemories"].click()
        waitForNativeStatus("Submitted to Codex", in: app)
        XCTAssertEqual(
            try String(contentsOf: fixture.destination.appending(path: "customer.md"), encoding: .utf8), updated)
        app.buttons["refreshNativeMemory"].click()
        waitForNativeStatus("No pending import", in: app)
        XCTAssertFalse(app.buttons["importClaudeMemories"].isEnabled)
        attachScreenshot(of: app, named: "Native memory — large library update confirmed")
    }

    @MainActor
    func testNativeMemoryLocationsAndActionsRemainUsableAtMaximumZoom() throws {
        let fixture = try makeNativeMemoryFixture(hasMemories: false)
        let app = fixture.app
        app.launch()
        defer { app.terminate() }
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 720, height: 620))
        openNativeMemory(in: app)
        waitForNativeStatus("Import unavailable", in: app)
        let refresh = app.buttons["refreshNativeMemory"]
        let originalHeight = refresh.frame.height
        for _ in 0..<5 { app.typeKey("=", modifierFlags: .command) }
        XCTAssertGreaterThan(refresh.frame.height, originalHeight * 1.9)
        let locations = app.buttons["nativeMemoryLocations"]
        revealNativeMemoryDetail(locations, in: app)
        locations.click()
        let path = app.staticTexts["nativeMemoryPath-Codex"]
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        revealNativeMemoryDetail(path, in: app)
        XCTAssertTrue(refresh.isHittable)
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.isHittable)
        let window = app.windows.firstMatch.frame
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let visibleScreens = NSScreen.screens.map { screen in
            let frame = screen.visibleFrame
            return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
        }
        for control in [refresh, done] {
            XCTAssertGreaterThanOrEqual(control.frame.minX, window.minX)
            XCTAssertLessThanOrEqual(control.frame.maxX, window.maxX)
            XCTAssertTrue(visibleScreens.contains { $0.contains(control.frame) }, app.debugDescription)
        }
        attachScreenshot(of: app, named: "Native memory — expanded locations at maximum zoom")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(refresh.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func revealNativeMemoryDetail(_ element: XCUIElement, in app: XCUIApplication) {
        let viewport = app.scrollViews["nativeMemoryDetails"]
        XCTAssertTrue(element.waitForExistence(timeout: 5), app.debugDescription)
        let needsHitTarget = element.elementType == .button
        if viewport.exists {
            for _ in 0..<12 {
                let visible = viewport.frame.intersection(element.frame)
                let isVisible = visible.height >= min(element.frame.height, viewport.frame.height) - 2
                if isVisible && (!needsHitTarget || element.isHittable) { break }
                let delta = min(80, max(-80, (viewport.frame.midY - element.frame.midY) / 2))
                viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    .scroll(byDeltaX: 0, deltaY: delta)
            }
            XCTAssertGreaterThanOrEqual(
                viewport.frame.intersection(element.frame).height, min(element.frame.height, viewport.frame.height) - 2,
                app.debugDescription)
        }
        if needsHitTarget { XCTAssertTrue(element.isHittable, app.debugDescription) }
    }
}
