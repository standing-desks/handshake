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
        app.typeKey(.escape, modifierFlags: [])
        let toggle = memorySharingToggle(in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.click()
        openHandshakeMemory(in: app)
        waitForHandshakeText("Sharing paused", identifier: "handshakeMemoryStatus", in: app)
        try "# Newly saved memory\nUse the amber lane.\n".write(
            to: fixture.source.appending(path: "new.md"), atomically: true, encoding: .utf8)
        app.typeKey(.escape, modifierFlags: [])
        openHandshakeMemory(in: app)
        waitForHandshakeText("Sharing paused", identifier: "handshakeMemoryStatus", in: app)
        waitForHandshakeText("0 project memories", identifier: "handshakeMemoryCount", in: app)
        app.typeKey(.escape, modifierFlags: [])
        toggle.click()
        openHandshakeMemory(in: app)
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
        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        for control in [sync] {
            XCTAssertTrue(control.isHittable, app.debugDescription)
            XCTAssertGreaterThanOrEqual(control.frame.minX, screen.minX)
            XCTAssertLessThanOrEqual(control.frame.maxX, screen.maxX)
        }
        let details = app.descendants(matching: .any).matching(identifier: "handshakeMemoryDetails").firstMatch
        revealHandshakeDetail(details, in: app)
        details.click()
        let path = app.staticTexts["handshakeMemoryPath-codex"]
        revealHandshakeDetail(path, in: app)
        XCTAssertTrue(staticTextValue(path).contains("native/codex"))
        XCTAssertTrue(sync.isHittable)
        attachScreenshot(of: app, named: "Handshake memories — storage details reachable at 200 percent")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(sync.waitForNonExistence(timeout: 5))
        let sidebar = app.scrollViews["sidebarViewport"]
        sidebar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).scroll(byDeltaX: 0, deltaY: -300)
        waitForMemoryHeaderHitTargets(in: app)
    }

    @MainActor
    func testMemoryHeaderSharingControlsRemainIndependentAndPersist() throws {
        let fixture = try makeAMISFixture()
        let app = fixture.app
        app.launch()
        setSidebar(open: true, in: app)
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1000, height: 800))
        let toggle = memorySharingToggle(in: app)
        let gear = app.buttons["openNativeMemory"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        waitForSharingToggle(true, in: app)
        let disclosure = app.buttons["memoryEntry-outline"]
        let wasExpanded = disclosure.value as? String
        XCTAssertGreaterThan(toggle.frame.minX, disclosure.frame.minX)
        XCTAssertGreaterThanOrEqual(gear.frame.minX, toggle.frame.maxX - 2)
        XCTAssertGreaterThanOrEqual(gear.frame.width, 24)
        XCTAssertGreaterThanOrEqual(gear.frame.height, 26)
        XCTAssertTrue(gear.isHittable)
        toggle.click()
        waitForSharingToggle(false, in: app)
        XCTAssertEqual(disclosure.value as? String, wasExpanded)
        openHandshakeMemory(in: app)
        waitForHandshakeText("Sharing paused", identifier: "handshakeMemoryStatus", in: app)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "handshakeMemoryEnabled").count, 1)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "memorySharingAgents").firstMatch.exists)
        XCTAssertEqual(app.sheets.count, 0, "Memory settings should be a transient popover.")
        attachScreenshot(of: app, named: "Grouped sharing switch and agent-neutral memory settings")
        app.typeKey(.escape, modifierFlags: [])
        app.terminate()
        app.launch()
        waitForSharingToggle(false, in: app)
        memorySharingToggle(in: app).click()
        waitForSharingToggle(true, in: app)
        let header = app.buttons["memoryEntry-outline"]
        header.click()
        waitForMemoryHeaderHitTargets(in: app)
        attachScreenshot(of: app, named: "Option 5 — native switch and gear beside Memories")
    }

    @MainActor
    func testMemoryHeaderOpensSettingsWhenPolicySaveFails() throws {
        let fixture = try makeAMISFixture()
        let app = fixture.app
        app.launch()
        setSidebar(open: true, in: app)
        defer { app.terminate() }
        waitForSharingToggle(true, in: app)
        let bindings = fixture.store.appending(path: "bindings.sqlite")
        try FileManager.default.moveItem(at: bindings, to: fixture.store.appending(path: "saved-bindings.sqlite"))
        try FileManager.default.createDirectory(at: bindings, withIntermediateDirectories: false)
        waitForSharingToggle(true, in: app)
        memorySharingToggle(in: app).click()
        let failure = app.staticTexts["handshakeMemoryFailure"]
        XCTAssertTrue(failure.waitForExistence(timeout: 15), app.debugDescription)
        let viewport = app.scrollViews["handshakeMemoryViewport"]
        XCTAssertGreaterThanOrEqual(
            viewport.frame.intersection(failure.frame).height, min(failure.frame.height, viewport.frame.height) - 2,
            app.debugDescription)
        XCTAssertTrue(app.buttons["handshakeMemorySync"].exists)
        XCTAssertEqual(app.sheets.count, 0)
        attachScreenshot(of: app, named: "Sharing policy failure is visible in memory settings")
    }

    @MainActor
    private func waitForMemoryHeaderHitTargets(in app: XCUIApplication) {
        let gear = app.buttons["openNativeMemory"]
        let toggle = memorySharingToggle(in: app)
        let visible = expectation(
            for: NSPredicate { _, _ in gear.isHittable && toggle.isHittable }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed, app.debugDescription)
    }

    @MainActor
    private func waitForSharingToggle(_ enabled: Bool, in app: XCUIApplication) {
        let toggle = memorySharingToggle(in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let matches = expectation(
            for: NSPredicate { _, _ in
                let value = (toggle.value as? NSNumber)?.boolValue ?? (toggle.value as? String == "1")
                return toggle.isEnabled && value == enabled
            }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 15), .completed, app.debugDescription)
    }

    @MainActor
    private func memorySharingToggle(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "handshakeMemoryEnabled").firstMatch
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
