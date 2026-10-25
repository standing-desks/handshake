import AppKit
import XCTest

extension TwineUITests {
    @MainActor
    func testTwineMemoriesAutomaticallyShareBothDirectionsAndSurviveRelaunch() throws {
        let fixture = try makeTwineMemoryFixture()
        let app = fixture.app
        app.launch()
        defer { app.terminate() }
        openTwineMemory(in: app)
        waitForTwineText("1 project memories", identifier: "twineMemoryCount", in: app)
        XCTAssertFalse(app.buttons["importClaudeMemories"].exists)
        let project = try fixture.projectRoot()
        let notes = project.appending(path: "native/codex/memories/extensions/ad_hoc/notes")
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: notes.path).contains { $0.hasPrefix("twine-") })
        try "# Release lane\n\nUse the green lane for this fictional project.\n".write(
            to: notes.appending(path: "new-codex-memory.md"), atomically: true, encoding: .utf8)
        waitForTwineText("2 project memories", identifier: "twineMemoryCount", in: app)
        waitForTwineText("Sharing automatically", identifier: "twineMemoryStatus", in: app)
        XCTAssertFalse(app.staticTexts["twineMemoryFailure"].exists)
        let claude = fixture.source.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "twine-\(project.lastPathComponent)/memory")
        let topics = try FileManager.default.contentsOfDirectory(at: claude, includingPropertiesForKeys: nil)
        XCTAssertTrue(
            try topics.filter { $0.lastPathComponent.hasPrefix("twine-shared-") }.contains {
                try String(contentsOf: $0, encoding: .utf8).contains("Use the green lane")
            })
        attachScreenshot(of: app, named: "Twine memories — automatic bidirectional AMIS sharing")
        app.terminate()
        app.launch()
        openTwineMemory(in: app)
        waitForTwineText("2 project memories", identifier: "twineMemoryCount", in: app)
    }

    @MainActor
    func testTwineMemoriesPauseResumeAndReopenWithoutImport() throws {
        let fixture = try makeTwineMemoryFixture(hasMemories: false)
        let app = fixture.app
        app.launch()
        defer { app.terminate() }
        openTwineMemory(in: app)
        waitForTwineText("0 project memories", identifier: "twineMemoryCount", in: app)
        let toggle = app.checkBoxes["twineMemoryEnabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.click()
        waitForTwineText("Sharing paused", identifier: "twineMemoryStatus", in: app)
        try "# Newly saved memory\nUse the amber lane.\n".write(
            to: fixture.source.appending(path: "new.md"), atomically: true, encoding: .utf8)
        app.typeKey(.escape, modifierFlags: [])
        openTwineMemory(in: app)
        waitForTwineText("Sharing paused", identifier: "twineMemoryStatus", in: app)
        waitForTwineText("0 project memories", identifier: "twineMemoryCount", in: app)
        toggle.click()
        waitForTwineText("1 project memories", identifier: "twineMemoryCount", in: app)
        XCTAssertFalse(app.staticTexts["twineMemoryFailure"].exists)
    }

    @MainActor
    func testTwineMemoriesRemainUsableAtMaximumZoom() throws {
        let fixture = try makeTwineMemoryFixture()
        let app = fixture.app
        app.launch()
        defer { app.terminate() }
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 720, height: 620))
        openTwineMemory(in: app)
        waitForTwineText("1 project memories", identifier: "twineMemoryCount", in: app)
        let sync = app.buttons["twineMemorySync"]
        let originalHeight = sync.frame.height
        for _ in 0..<5 { app.typeKey("=", modifierFlags: .command) }
        XCTAssertGreaterThan(sync.frame.height, originalHeight * 1.9)
        let window = app.windows.firstMatch.frame
        let done = app.buttons["Done"].firstMatch
        for control in [sync, done] {
            XCTAssertTrue(control.isHittable, app.debugDescription)
            XCTAssertGreaterThanOrEqual(control.frame.minX, window.minX)
            XCTAssertLessThanOrEqual(control.frame.maxX, window.maxX)
        }
        attachScreenshot(of: app, named: "Twine memories — narrow window at 200 percent")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(sync.waitForNonExistence(timeout: 5))
    }
}
