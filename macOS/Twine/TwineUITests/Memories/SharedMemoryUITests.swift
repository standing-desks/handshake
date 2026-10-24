import XCTest

extension TwineUITests {
    @MainActor
    func testSharedMemoryPolicyAddAndWithdraw() throws {
        let folder = try makeTestFolder(prefix: "TwineSharedMemoryUI")
        let app = try makeApp(lastOpenFolder: folder)
        app.launch()
        defer { app.terminate() }
        let shared = app.buttons["openSharedMemory"]
        if !shared.waitForExistence(timeout: 10) { sidebarToggle(in: app).click() }
        XCTAssertTrue(shared.waitForExistence(timeout: 10))
        shared.click()
        let policy = app.checkBoxes["sharedMemoryPolicy"]
        XCTAssertTrue(policy.waitForExistence(timeout: 10))
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: policy)
        waitForExpectations(timeout: 10)
        policy.click()
        let draft = app.textViews["sharedMemoryDraft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        draft.click()
        draft.typeText("# Shared trial\nRun the cedar checklist.")
        let share = app.buttons["shareMemoryNote"]
        expectation(for: enabled, evaluatedWith: share)
        waitForExpectations(timeout: 10)
        share.click()
        let withdraw = app.buttons["Withdraw from shared memory"]
        XCTAssertTrue(withdraw.waitForExistence(timeout: 10))
        let content = app.staticTexts["sharedMemoryContent"]
        XCTAssertTrue(content.waitForExistence(timeout: 10))
        let displayed = content.value as? String ?? content.label
        XCTAssertTrue(displayed.contains("Run the cedar checklist."), content.debugDescription)
        attachScreenshot(of: app, named: "Shared memory accepted note")
        withdraw.click()
        XCTAssertTrue(app.staticTexts["Withdrawn"].waitForExistence(timeout: 10))
        policy.click()
        XCTAssertTrue(app.buttons["Done"].exists)
    }
}
