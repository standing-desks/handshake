import XCTest

@MainActor
struct WorkflowGraphExampleUI {
    let app: XCUIApplication
    let testCase: XCTestCase

    func item(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    func replace(_ id: String, with text: String) {
        let field = item(id)
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        reveal(field)
        field.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText(text)
    }
    func drag(_ source: XCUIElement, to destination: XCUIElement) {
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click(
                forDuration: 0.1, thenDragTo: destination.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
    }
    func chooseOption(_ title: String) {
        let option = app.radioButtons.matching(NSPredicate(format: "label ENDSWITH %@", title)).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription)
        option.click()
    }
    func reveal(_ control: XCUIElement) {
        let popover = app.popovers.firstMatch
        guard popover.exists else { return }
        let content = popover.scrollViews.firstMatch
        guard content.exists else { return }
        for _ in 0..<8 {
            let visible = content.frame.intersection(popover.frame).insetBy(dx: 4, dy: 4)
            let center = CGPoint(x: control.frame.midX, y: control.frame.midY)
            if visible.contains(center), control.isHittable { return }
            content.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .scroll(byDeltaX: 0, deltaY: center.y < visible.minY ? 80 : -80)
        }
        XCTAssertTrue(control.isHittable, app.debugDescription)
    }

    func click(_ id: String) {
        let control = item(id)
        reveal(control)
        control.click()
    }

    func chooseAnswerType(_ title: String) {
        click("decisionAnswerType")
        app.menuItems[title].click()
    }

    var router: XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'graphNode-' AND label CONTAINS 'Router'"))
            .firstMatch
    }

    func verifyYesNo() {
        router.click()
        chooseAnswerType("Yes/No")
        XCTAssertTrue(item("decisionAnswer-yes").waitForExistence(timeout: 5))
        XCTAssertFalse(app.popovers.firstMatch.frame.contains(CGPoint(x: router.frame.midX, y: router.frame.midY)))
        XCTAssertFalse(app.radioButtons["Launch defaults"].exists)
        replace("decisionYesThreshold", with: "63.5")
        app.buttons["Done"].click()
        router.click()
        XCTAssertEqual(item("decisionYesThreshold").value as? String, "63.5")
        item("decisionSwapAnswers").click()
        app.buttons["Done"].click()
        XCTAssertTrue(app.buttons["Router to Builder: No"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Router to Planner: Yes"].exists)
        router.click()
        click("decisionUncertain")
        replace("decisionYesThreshold", with: "87.5")
        replace("decisionNoThreshold", with: "12.5")
        click("decisionUncertain")
        XCTAssertEqual(item("decisionYesThreshold").value as? String, "63.5")
        click("decisionUncertain")
        XCTAssertEqual(item("decisionYesThreshold").value as? String, "87.5")
        app.buttons["Done"].click()
        XCTAssertFalse(item("designerSave").isEnabled)
        item("designerDecisionValidation").click()
        XCTAssertTrue(app.staticTexts["Connect one agent for Uncertain."].waitForExistence(timeout: 5))
        app.buttons["Done"].click()
        let canvas = item("designerContent")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).doubleClick()
        replace("graphAgentName", with: "Escalator")
        app.buttons["Done"].click()
        drag(app.buttons["Connect from Router"], to: app.buttons["Connect to Escalator"])
        XCTAssertTrue(app.buttons["Router to Escalator: Uncertain"].waitForExistence(timeout: 5))
        saveAndReopen()
    }

    func verifyScore() {
        router.click()
        chooseAnswerType("Score")
        let question = item("decisionQuestion")
        question.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])
        app.buttons["Done"].click()
        item("designerDecisionValidation").click()
        XCTAssertTrue(app.staticTexts["Enter a question for this decision."].waitForExistence(timeout: 5))
        replace("decisionQuestion", with: "How much attention does this work need?")
        let move = app.buttons["Move Escalator up"]
        reveal(move)
        move.click()
        move.click()
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Ordered score levels and square diamond"
        image.lifetime = .keepAlways
        testCase.add(image)
        app.buttons["Done"].click()
        saveAndReopen()
        XCTAssertTrue(app.buttons["Router to Escalator: 0 · Escalator"].exists)
        XCTAssertTrue(app.buttons["Router to Builder: 1 · Builder"].exists)
        XCTAssertTrue(app.buttons["Router to Planner: 2 · Planner"].exists)
        for _ in 0..<4 { app.buttons["Zoom out"].click() }
        XCTAssertGreaterThanOrEqual(app.buttons["Connect from Router"].frame.width, 27)
        XCTAssertGreaterThanOrEqual(app.buttons["Connect to Planner"].frame.height, 27)
    }

    func saveAndReopen() {
        let save = item("designerSave")
        let ready = testCase.expectation(for: NSPredicate { _, _ in save.exists && save.isEnabled }, evaluatedWith: nil)
        testCase.wait(for: [ready], timeout: 10)
        save.click()
        XCTAssertTrue(item("workflowEditType").waitForExistence(timeout: 10), app.debugDescription)
        item("workflowEditType").click()
        XCTAssertTrue(item("designerName").waitForExistence(timeout: 5))
    }
}
