import XCTest

extension HandshakeUITests {
    @MainActor
    func testPDFImageAndVideoPreviewsShareFileTabControls() async throws {
        let folder = try makeTestFolder(prefix: "HandshakeMediaPreviews")
        try await MediaFixtures.make(in: folder)
        let app = try managedTabApp(folder: folder)
        app.launchArguments += ["-AppleShowScrollBars", "Always"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 920, height: 676))
        setSidebar(open: true, in: app)
        for (name, identifier, document) in [
            ("sample.pdf", "pdfPreview", "pdfDocument"), ("sample-large.png", "imagePreview", "imageDocument"),
            ("sample.mov", "videoPreview", "videoPlayer"),
        ] {
            let url = folder.appending(path: name)
            let row = fileRow(url, in: app)
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.click()
            XCTAssertTrue(
                app.descendants(matching: .any)[identifier].waitForExistence(timeout: 10), app.debugDescription)
            verifyNativeMediaContent(document, in: app)
            XCTAssertFalse(app.staticTexts["Binary File"].exists)
            XCTAssertFalse(app.staticTexts["File Too Large"].exists)
            XCTAssertFalse(app.descendants(matching: .any)["mediaFailure"].exists)
            XCTAssertFalse(app.buttons["goToLine"].isEnabled)
            if document == "videoPlayer" { verifyVideoPausesWhenHidden(url: url, in: app) }
            attachScreenshot(of: app, named: "Native \(name) viewer")
        }
        app.typeKey("1", modifierFlags: .command)
        waitForTab(app.buttons["workflowTab-1"], valueContaining: "Selected", in: app)
        app.typeKey("t", modifierFlags: [.command, .option])
        let browser = browserTabs(in: app).firstMatch
        XCTAssertTrue(browser.waitForExistence(timeout: 5))
        let pdfURL = folder.appending(path: "sample.pdf")
        let pdf = fileTab(pdfURL, in: app)
        selectMediaTab(pdfURL, in: app)
        app.typeKey("p", modifierFlags: [.command, .shift])
        waitForTab(pdf, valueContaining: "Pinned", in: app)
        selectMediaTab(pdfURL, in: app)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(pdf.waitForNonExistence(timeout: 5))
        app.typeKey("t", modifierFlags: [.command, .shift])
        XCTAssertTrue(pdf.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["pdfPreview"].waitForExistence(timeout: 10))
        waitForTab(pdf, valueContaining: "Pinned", in: app)
    }

    @MainActor
    private func selectMediaTab(_ url: URL, in app: XCUIApplication) {
        app.typeKey("a", modifierFlags: [.command, .shift])
        let search = app.textFields["tabSwitcherSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
        search.typeText(url.lastPathComponent)
        search.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5), app.debugDescription)
        waitForTab(fileTab(url, in: app), valueContaining: "Selected", in: app)
    }
    @MainActor
    private func verifyNativeMediaContent(_ document: String, in app: XCUIApplication) {
        if document == "pdfDocument" {
            let text = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Handshake PDF fixture"))
                .firstMatch
            XCTAssertTrue(text.waitForExistence(timeout: 10), app.debugDescription)
            let next = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Second PDF page")).firstMatch
            let viewport = app.descendants(matching: .any)["fileViewport"]
            for _ in 0..<5 {
                if next.exists && next.isHittable { break }
                viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).scroll(byDeltaX: 0, deltaY: -700)
            }
            XCTAssertTrue(next.isHittable, app.debugDescription)
        } else if document == "videoPlayer" {
            app.descendants(matching: .any)["videoPreview"].hover()
            let ready = app.buttons["Play"].firstMatch.waitForExistence(timeout: 10)
            attachScreenshot(of: app, named: "Video preview and native controls")
            XCTAssertTrue(ready, app.debugDescription)
        } else {
            XCTAssertTrue(app.images[document].waitForExistence(timeout: 10), app.debugDescription)
        }
    }

    @MainActor
    private func verifyVideoPausesWhenHidden(url: URL, in app: XCUIApplication) {
        let play = app.buttons.matching(NSPredicate(format: "label ==[c] %@", "Play")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5), app.debugDescription)
        play.click()
        let pause = app.buttons["Pause"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        pause.click()
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        let position = app.sliders["videoPosition"]
        position.adjust(toNormalizedSliderPosition: 0.5)
        let scrubbed = expectation(
            for: NSPredicate { _, _ in
                let value = (position.value as? NSNumber)?.doubleValue ?? -1
                let time = app.staticTexts["videoTime"].value as? String ?? ""
                return abs(value - 5) < 0.15 && ["0:04", "0:05"].contains(time)
            }, evaluatedWith: nil)
        let displayedTime = String(describing: app.staticTexts["videoTime"].value)
        XCTAssertEqual(
            XCTWaiter.wait(for: [scrubbed], timeout: 5), .completed,
            "Time: \(displayedTime); slider: \(String(describing: position.value))")
        let beforeArrow = (position.value as? NSNumber)?.doubleValue
        position.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertNotEqual((position.value as? NSNumber)?.doubleValue, beforeArrow)
        position.adjust(toNormalizedSliderPosition: 0.5)
        app.typeKey("1", modifierFlags: .command)
        waitForTab(app.buttons["workflowTab-1"], valueContaining: "Selected", in: app)
        selectMediaTab(url, in: app)
        XCTAssertTrue(play.waitForExistence(timeout: 5), app.debugDescription)
        let retainedTime = app.staticTexts["videoTime"].value as? String ?? ""
        XCTAssertTrue(["0:04", "0:05"].contains(retainedTime), retainedTime)
        play.click()
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        app.typeKey("1", modifierFlags: .command)
        waitForTab(app.buttons["workflowTab-1"], valueContaining: "Selected", in: app)
        selectMediaTab(url, in: app)
        XCTAssertTrue(play.waitForExistence(timeout: 5), app.debugDescription)
    }

}
