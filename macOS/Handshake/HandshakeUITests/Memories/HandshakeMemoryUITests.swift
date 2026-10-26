import AppKit
import Darwin
import XCTest

extension HandshakeUITests {
    @MainActor
    func testHandshakeMemoriesAutomaticallyShareBothDirectionsAndSurviveRelaunch() throws {
        let fixture = try makeAMISFixture()
        let app = fixture.app
        app.launch()
        defer { app.terminate() }
        openHandshakeMemory(in: app)
        waitForHandshakeText("1 project memories", identifier: "handshakeMemoryCount", in: app)
        XCTAssertFalse(app.buttons["importClaudeMemories"].exists)
        let project = try fixture.projectRoot()
        let notes = project.appending(path: "native/codex/memories/extensions/ad_hoc/notes")
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: notes.path).contains { $0.hasPrefix("twine-") })
        try "# Release lane\n\nUse the green lane for this fictional project.\n".write(
            to: notes.appending(path: "new-codex-memory.md"), atomically: true, encoding: .utf8)
        waitForHandshakeText("2 project memories", identifier: "handshakeMemoryCount", in: app)
        waitForHandshakeText("Sharing automatically", identifier: "handshakeMemoryStatus", in: app)
        XCTAssertFalse(app.staticTexts["handshakeMemoryFailure"].exists)
        let claude = fixture.source.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "twine-\(project.lastPathComponent)/memory")
        let topics = try FileManager.default.contentsOfDirectory(at: claude, includingPropertiesForKeys: nil)
        XCTAssertTrue(
            try topics.filter { $0.lastPathComponent.hasPrefix("twine-shared-") }.contains {
                try String(contentsOf: $0, encoding: .utf8).contains("Use the green lane")
            })
        let codexProjection = notes.appending(
            path: "twine-\(try XCTUnwrap(activeMemoryID(in: project, containing: "maple-417"))).md")
        let edited = try String(contentsOf: codexProjection, encoding: .utf8).replacingOccurrences(
            of: "maple-417", with: "maple-418")
        try edited.write(to: codexProjection, atomically: true, encoding: .utf8)
        let updated = expectation(
            for: NSPredicate { _, _ in
                (try? activeMemoryID(in: project, containing: "maple-418")) != nil
            }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 20), .completed)
        waitForHandshakeText("Sharing automatically", identifier: "handshakeMemoryStatus", in: app)
        let active = try XCTUnwrap(activeMemoryID(in: project, containing: "maple-418"))
        waitForFile(claude.appending(path: "twine-shared-\(active).md"), containing: "maple-418", in: app)
        attachScreenshot(of: app, named: "Handshake memories — automatic sharing and native revision update")
        app.terminate()
        app.launch()
        openHandshakeMemory(in: app)
        waitForHandshakeText("2 project memories", identifier: "handshakeMemoryCount", in: app)
    }

    @MainActor
    func testHandshakeMemoriesPauseResumeAndReopenWithoutImport() throws {
        let fixture = try makeAMISFixture(hasMemories: false)
        let app = fixture.app
        app.launch()
        defer { app.terminate() }
        openHandshakeMemory(in: app)
        waitForHandshakeText("0 project memories", identifier: "handshakeMemoryCount", in: app)
        let toggle = app.checkBoxes["handshakeMemoryEnabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.click()
        waitForHandshakeText("Sharing paused", identifier: "handshakeMemoryStatus", in: app)
        try "# Newly saved memory\nUse the amber lane.\n".write(
            to: fixture.source.appending(path: "new.md"), atomically: true, encoding: .utf8)
        app.typeKey(.escape, modifierFlags: [])
        openHandshakeMemory(in: app)
        waitForHandshakeText("Sharing paused", identifier: "handshakeMemoryStatus", in: app)
        waitForHandshakeText("0 project memories", identifier: "handshakeMemoryCount", in: app)
        toggle.click()
        waitForHandshakeText("1 project memories", identifier: "handshakeMemoryCount", in: app)
        XCTAssertFalse(app.staticTexts["handshakeMemoryFailure"].exists)
    }

    @MainActor
    func testHandshakeMemoriesRemainUsableAtMaximumZoom() throws {
        let fixture = try makeAMISFixture()
        let app = fixture.app
        app.launch()
        defer { app.terminate() }
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 720, height: 620))
        openHandshakeMemory(in: app)
        waitForHandshakeText("1 project memories", identifier: "handshakeMemoryCount", in: app)
        let sync = app.buttons["handshakeMemorySync"]
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
        let details = app.descendants(matching: .any).matching(identifier: "handshakeMemoryDetails").firstMatch
        revealHandshakeDetail(details, in: app)
        details.click()
        let path = app.staticTexts["handshakeMemoryPath-Codex native home"]
        revealHandshakeDetail(path, in: app)
        XCTAssertTrue(staticTextValue(path).contains("native/codex"))
        XCTAssertTrue(sync.isHittable && done.isHittable)
        attachScreenshot(of: app, named: "Handshake memories — storage details reachable at 200 percent")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(sync.waitForNonExistence(timeout: 5))
    }
    @MainActor
    func testHandshakeMemoriesDeferActiveProfileWithoutReportingFailedSync() throws {
        let fixture = try makeAMISFixture()
        let app = fixture.app
        app.launch()
        defer { app.terminate() }
        openHandshakeMemory(in: app)
        waitForHandshakeText("1 project memories", identifier: "handshakeMemoryCount", in: app)
        let project = try fixture.projectRoot()
        let descriptor = open(project.appending(path: "native-sessions-codex.lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_SH | LOCK_NB), 0)
        try "# Deferred memory\nUse the amber release lane.\n".write(
            to: fixture.source.appending(path: "deferred.md"), atomically: true, encoding: .utf8)
        app.buttons["handshakeMemorySync"].click()
        waitForHandshakeText("Waiting to reconcile", identifier: "handshakeMemoryStatus", in: app)
        XCTAssertFalse(app.staticTexts["handshakeMemoryFailure"].exists, "A native session lease is normal deferral.")
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        waitForHandshakeText("Sharing automatically", identifier: "handshakeMemoryStatus", in: app)
        waitForHandshakeText("2 project memories", identifier: "handshakeMemoryCount", in: app)
        XCTAssertFalse(app.staticTexts["handshakeMemoryFailure"].exists)
    }

    @MainActor
    private func revealHandshakeDetail(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), app.debugDescription)
        let viewport = app.scrollViews["handshakeMemoryViewport"]
        for _ in 0..<12 {
            let visible = viewport.frame.intersection(element.frame)
            let needsHitTarget = element.elementType == .button || element.elementType == .disclosureTriangle
            let fullyVisible = visible.height >= min(element.frame.height, viewport.frame.height) - 2
            let canActivate = !needsHitTarget || element.isHittable
            if fullyVisible && canActivate { return }
            let delta = min(90, max(-90, (viewport.frame.midY - element.frame.midY) / 2))
            viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).scroll(byDeltaX: 0, deltaY: delta)
        }
        XCTAssertGreaterThanOrEqual(
            viewport.frame.intersection(element.frame).height,
            min(element.frame.height, viewport.frame.height) - 2, app.debugDescription)
        if element.elementType == .button { XCTAssertTrue(element.isHittable, app.debugDescription) }
    }

}

private func activeMemoryID(in project: URL, containing text: String) throws -> String? {
    let bytes = try Data(contentsOf: project.appending(path: "library.amis.json"))
    let bundle = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    let records = try XCTUnwrap(bundle["records"] as? [[String: Any]])
    var heads: [String: [String: Any]] = [:]
    for record in records { if let id = record["id"] as? String { heads[id] = record } }
    return heads.first { _, record in
        record["status"] as? String == "active"
            && (record["extensions"] as? [String: Any])?["com.twine.consolidation"] != nil
            && ((record["body"] as? [String: Any])?["text"] as? String)?.contains(text) == true
    }?.key
}
