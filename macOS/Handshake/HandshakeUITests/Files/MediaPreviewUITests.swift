import XCTest

extension HandshakeUITests {
    @MainActor
    func testPDFImageAndVideoPreviewsShareFileTabControls() async throws {
        let folder = try makeTestFolder(prefix: "HandshakeMediaPreviews")
        try await MediaFixtures.make(in: folder)
        let app = try managedTabApp(folder: folder)
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1200, height: 800))
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
            XCTAssertTrue(app.descendants(matching: .any)[document].waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertFalse(app.staticTexts["Binary File"].exists)
            XCTAssertFalse(app.staticTexts["File Too Large"].exists)
            XCTAssertFalse(app.descendants(matching: .any)["mediaFailure"].exists)
            XCTAssertFalse(app.buttons["goToLine"].isEnabled)
            attachScreenshot(of: app, named: "Native \(name) viewer")
        }
        app.buttons["workflowTab-1"].click()
        app.typeKey("t", modifierFlags: [.command, .option])
        let browser = browserTabs(in: app).firstMatch
        XCTAssertTrue(browser.waitForExistence(timeout: 5))
        let pdf = fileTab(folder.appending(path: "sample.pdf"), in: app)
        pdf.click()
        app.typeKey("p", modifierFlags: [.command, .shift])
        waitForTab(pdf, valueContaining: "Pinned", in: app)
        app.typeKey("a", modifierFlags: [.command, .shift])
        let search = app.textFields["tabSwitcherSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("sample.pdf")
        search.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
        waitForTab(pdf, valueContaining: "Selected", in: app)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(pdf.waitForNonExistence(timeout: 5))
        app.typeKey("t", modifierFlags: [.command, .shift])
        XCTAssertTrue(pdf.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["pdfPreview"].waitForExistence(timeout: 10))
        waitForTab(pdf, valueContaining: "Pinned", in: app)
    }
}
