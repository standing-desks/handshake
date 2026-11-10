import AppKit
import IOKit.pwr_mgt
import XCTest

extension HandshakeUITests {
    @MainActor
    func testKeepAwakeMenuWorksOnOpeningScreenAndSharesToolbarState() throws {
        let folder = try makeTestFolder(prefix: "Handshake keep awake menu")
        let app = try makeApp()
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Welcome to Handshake"].waitForExistence(timeout: 10))
        XCTAssertFalse(keepAwakeControl(in: app.windows.firstMatch).exists)
        let parent = try keepAwakeAppPID()
        app.menuBars.menuBarItems["Handshake"].click()
        XCTAssertTrue(app.menuItems["Keep Awake"].waitForExistence(timeout: 5))
        app.menuItems["Keep Awake"].click()
        let child = try waitForCaffeinate(parent: parent)
        try waitForPowerAssertions(child)
        app.menuBars.menuBarItems["Handshake"].click()
        attachScreenshot(of: app, named: "App menu with Keep Awake enabled on the opening screen")
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertEqual(kill(child, SIGKILL), 0)
        let alert = app.sheets.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(alert.staticTexts["Keep Awake stopped unexpectedly. Turn it on again to retry."].exists)
        clickDialogButton("OK", in: app)
        openKeepAwakeFolder(folder, in: app)
        let toggle = keepAwakeControl(in: app.windows.firstMatch)
        waitForKeepAwake(toggle, "Off")
        XCTAssertEqual(toggle.label, "Keep Awake")
        XCTAssertGreaterThanOrEqual(toggle.frame.width, 28)
        XCTAssertGreaterThanOrEqual(toggle.frame.height, 28)
        toggle.click()
        waitForKeepAwake(toggle, "On")
        let replacement = try waitForCaffeinate(parent: parent)
        app.menuBars.menuBarItems["Handshake"].click()
        app.menuItems["Keep Awake"].click()
        waitForKeepAwake(toggle, "Off")
        XCTAssertTrue(processEnds(replacement))
    }

    @MainActor
    func testKeepAwakeSharesWindowsStopsOnQuitAndRelaunchesOff() throws {
        let folder = try makeTestFolder(prefix: "Handshake keep awake first")
        let secondFolder = try makeTestFolder(prefix: "Handshake keep awake second")
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["HANDSHAKE_TEST_APPEARANCE"] = "Light"
        app.launch()
        defer { app.terminate() }
        let first = app.windows.firstMatch
        let button = keepAwakeControl(in: first)
        waitForKeepAwake(button, "Off")
        XCTAssertGreaterThan(button.frame.midX, first.frame.midX)
        XCTAssertLessThan(button.frame.maxY, first.frame.minY + 85)
        attachWindow(in: app, name: "Keep Awake off in the native toolbar")
        let parent = try keepAwakeAppPID()
        button.click()
        waitForKeepAwake(button, "On")
        attachWindow(in: app, name: "Keep Awake on in the native toolbar")
        let child = try waitForCaffeinate(parent: parent)
        try waitForPowerAssertions(child)

        app.typeKey("n", modifierFlags: .command)
        let twoWindows = expectation(for: NSPredicate { _, _ in app.windows.count == 2 }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [twoWindows], timeout: 10), .completed)
        openKeepAwakeFolder(secondFolder, in: app)
        waitForKeepAwakeInAllWindows("On", in: app)
        XCTAssertEqual(try caffeinateChildren(parent: parent), [child], "Windows must share one process")
        let front = keepAwakeControl(in: app.windows.element(boundBy: 0))
        front.click()
        waitForKeepAwakeInAllWindows("Off", in: app)
        XCTAssertTrue(processEnds(child))
        front.click()
        waitForKeepAwake(front, "On")
        let running = try waitForCaffeinate(parent: parent)
        for _ in 0..<2 {
            app.windows.element(boundBy: 0).buttons[XCUIIdentifierCloseWindow].click()
        }
        XCTAssertTrue(app.windows.allElementsBoundByIndex.isEmpty)
        XCTAssertEqual(
            try caffeinateChildren(parent: parent), [running], "Closing windows must preserve app-wide state")
        app.typeKey("n", modifierFlags: .command)
        openKeepAwakeFolder(folder, in: app)
        waitForKeepAwake(keepAwakeControl(in: app), "On")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        XCTAssertTrue(processEnds(running), "Normal quit must reap caffeinate")
        try assertNoPowerAssertions(running)
        app.launch()
        waitForKeepAwake(keepAwakeControl(in: app), "Off")
        XCTAssertTrue(try caffeinateChildren(parent: keepAwakeAppPID()).isEmpty)
    }

    @MainActor
    func testKeepAwakeRecoversChildFailureAndReleasesAfterForceQuit() throws {
        let folder = try makeTestFolder(prefix: "Handshake keep awake")
        let secondFolder = try makeTestFolder(prefix: "Handshake keep awake second")
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["HANDSHAKE_TEST_APPEARANCE"] = "Dark"
        app.launch()
        defer { app.terminate() }
        let button = keepAwakeControl(in: app)
        waitForKeepAwake(button, "Off")
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 400, height: 302))
        if button.isHittable {
            button.click()
        } else {
            app.popUpButtons["more toolbar items"].click()
            app.menuItems["Keep Awake"].click()
        }
        let parent = try keepAwakeAppPID()
        let child = try waitForCaffeinate(parent: parent)
        try waitForPowerAssertions(child)
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 900, height: 620))
        assertKeepAwakePlacement(in: app)
        app.typeKey("n", modifierFlags: .command)
        openKeepAwakeFolder(secondFolder, in: app)
        let frontButton = keepAwakeControl(in: app.windows.element(boundBy: 0))
        waitForKeepAwake(frontButton, "On")
        XCTAssertEqual(kill(child, SIGKILL), 0)
        let alert = app.sheets.matching(NSPredicate(format: "label == %@", "alert"))
        XCTAssertTrue(alert.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        // An alert becoming key must not dismiss it on a later state poll or duplicate it per window.
        RunLoop.current.run(until: Date().addingTimeInterval(2.2))
        XCTAssertEqual(alert.count, 1)
        XCTAssertTrue(
            alert.firstMatch.staticTexts.allElementsBoundByIndex.contains {
                staticTextValue($0) == "Keep Awake stopped unexpectedly. Turn it on again to retry."
            })
        clickDialogButton("OK", in: app)
        waitForKeepAwake(frontButton, "Off")
        XCTAssertTrue(processEnds(child))
        frontButton.click()
        waitForKeepAwake(frontButton, "On")
        let replacement = try waitForCaffeinate(parent: parent)
        try waitForPowerAssertions(replacement)
        XCTAssertEqual(kill(parent, SIGKILL), 0)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        XCTAssertTrue(processEnds(replacement), "The PID watcher must release sleep prevention after a crash")
        try assertNoPowerAssertions(replacement)
        app.launch()
        waitForKeepAwakeInAllWindows("Off", in: app)
    }

    @MainActor
    private func waitForKeepAwakeInAllWindows(_ value: String, in app: XCUIApplication) {
        let controls = app.windows.descendants(matching: .any).matching(identifier: "keepAwake")
        let ready = expectation(for: NSPredicate { _, _ in controls.count == 2 }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        for control in controls.allElementsBoundByIndex {
            waitForKeepAwake(control, value)
        }
    }

    @MainActor
    private func openKeepAwakeFolder(_ folder: URL, in app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Welcome to Handshake"].waitForExistence(timeout: 10))
        let openingWindow = app.windows.containing(.staticText, identifier: "Welcome to Handshake").firstMatch
        XCTAssertFalse(keepAwakeControl(in: openingWindow).exists)
        app.typeKey("o", modifierFlags: .command)
        let picker = app.sheets.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), app.debugDescription)
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(folder.path + "\r")
        let open = picker.buttons["Open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5), app.debugDescription)
        open.click()
        XCTAssertTrue(picker.waitForNonExistence(timeout: 10), app.debugDescription)
        let folderWindow = app.windows.matching(NSPredicate(format: "title BEGINSWITH %@", folder.lastPathComponent))
            .firstMatch
        XCTAssertTrue(keepAwakeControl(in: folderWindow).waitForExistence(timeout: 10))
    }

    @MainActor
    private func assertKeepAwakePlacement(in app: XCUIApplication) {
        guard #available(macOS 26.1, *) else { return }
        let button = keepAwakeControl(in: app)
        waitForKeepAwake(button, "On")
        XCTAssertTrue(button.isHittable)
        XCTAssertLessThan(app.windows.firstMatch.frame.maxX - button.frame.maxX, 65)
        attachWindow(in: app, name: "Keep Awake in the top-right toolbar")
    }

    @MainActor
    private func waitForKeepAwake(_ button: XCUIElement, _ value: String) {
        let ready = expectation(
            for: NSPredicate { _, _ in
                button.exists && button.isEnabled
                    && String(describing: button.value ?? "") == (value == "On" ? "1" : "0")
            },
            evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, button.debugDescription)
    }

    @MainActor
    private func keepAwakeControl(in element: XCUIElement) -> XCUIElement {
        element.descendants(matching: .any).matching(identifier: "keepAwake").firstMatch
    }

    private func keepAwakeAppPID() throws -> pid_t {
        let identifier =
            ProcessInfo.processInfo.environment["HANDSHAKE_UI_TEST_APP_PATH"].flatMap {
                Bundle(url: URL(filePath: $0))?.bundleIdentifier
            } ?? "com.twineproject.Twine.development"
        return try XCTUnwrap(
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first?.processIdentifier)
    }

    private func caffeinateChildren(parent: pid_t) throws -> [pid_t] {
        try powerAssertions().compactMap { pid, assertions in
            assertions.contains {
                $0["AssertionOnBehalfOfPID"] as? Int32 == parent
                    && $0[kIOPMAssertionNameKey as String] as? String == "caffeinate command-line tool"
            } ? pid.int32Value : nil
        }.sorted()
    }

    private func waitForCaffeinate(parent: pid_t) throws -> pid_t {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if let pid = try caffeinateChildren(parent: parent).first { return pid }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        throw NSError(
            domain: "KeepAwakeUITests", code: 1, userInfo: [NSLocalizedDescriptionKey: "caffeinate did not start"])
    }

    private func waitForPowerAssertions(_ pid: pid_t) throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            let assertions = try powerAssertions()[NSNumber(value: pid)] ?? []
            let types = assertions.compactMap { $0[kIOPMAssertionTypeKey as String] as? String }
            let system = types.contains(kIOPMAssertionTypePreventUserIdleSystemSleep)
            let display = types.contains(kIOPMAssertionTypePreventUserIdleDisplaySleep)
            if system && display { return }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        XCTFail("Keep Awake did not create the real idle-system and display-sleep assertions")
    }

    private func assertNoPowerAssertions(_ pid: pid_t) throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if try powerAssertions()[NSNumber(value: pid)] == nil { return }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        XCTFail("Sleep-prevention assertions survived their process")
    }

    private func powerAssertions() throws -> [NSNumber: [[String: Any]]] {
        var result: Unmanaged<CFDictionary>?
        XCTAssertEqual(IOPMCopyAssertionsByProcess(&result), kIOReturnSuccess)
        return try XCTUnwrap(result?.takeRetainedValue() as? [NSNumber: [[String: Any]]])
    }
}
