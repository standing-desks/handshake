import XCTest

extension HandshakeUITests {
    @MainActor
    func testDraftChoicesAndTypingKeepThePromptUsable() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "HandshakeUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let app = try makeApp(lastOpenFolder: folder)
        app.launch()
        XCTAssertTrue(app.buttons["newWorkflow"].waitForExistence(timeout: 10), app.debugDescription)
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 900, height: 620))
        let terminalChoice = app.buttons["workflowChoice-Terminal"]
        XCTAssertTrue(terminalChoice.waitForExistence(timeout: 10), app.debugDescription)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "New workflow choices"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        terminalChoice.click()
        app.typeText("printf '%s' chosen > chosen.txt\r")
        let chosen = expectation(
            for: NSPredicate { _, _ in
                (try? String(contentsOf: folder.appending(path: "chosen.txt"), encoding: .utf8)) == "chosen"
            }, evaluatedWith: nil
        )
        wait(for: [chosen], timeout: 10)

        app.buttons["newWorkflow"].click()
        let coordinatorChoice = app.buttons["workflowChoice-Coordinator"]
        XCTAssertTrue(coordinatorChoice.waitForExistence(timeout: 10), app.debugDescription)
        coordinatorChoice.click()
        let start = app.descendants(matching: .any).matching(identifier: "workflowStart").firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["Back"].click()
        app.typeText("printf '%s' typed > typed.txt\r")
        let typed = expectation(
            for: NSPredicate { _, _ in
                (try? String(contentsOf: folder.appending(path: "typed.txt"), encoding: .utf8)) == "typed"
            }, evaluatedWith: nil
        )
        wait(for: [typed], timeout: 10)
        XCTAssertTrue(coordinatorChoice.waitForNonExistence(timeout: 10), app.debugDescription)

        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(terminalChoice.waitForExistence(timeout: 10), app.debugDescription)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(terminalChoice.waitForNonExistence(timeout: 10), app.debugDescription)
        app.terminate()
    }
}
