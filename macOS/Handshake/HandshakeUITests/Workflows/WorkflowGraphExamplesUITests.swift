import XCTest

extension HandshakeUITests {
    @MainActor
    func testReviewGraphCanBeCreatedFromBlankSavedAndReopened() throws {
        let app = try launchGraphDesigner()
        defer { app.terminate() }
        let editor = WorkflowGraphExampleUI(app: app, testCase: self)
        editor.item("workflowCreateOwn").click()
        editor.replace("designerName", with: "UI Adversarial")
        let canvas = editor.item("designerContent")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.35)).doubleClick()
        editor.replace("graphAgentName", with: "Implementer")
        app.buttons["Done"].click()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6)).rightClick()
        app.menuItems["Add agent"].click()
        editor.replace("graphAgentName", with: "Reviewer")
        app.buttons["Done"].click()
        // Drag from the receiving port to the sending port. Direction remains Implementer to Reviewer.
        editor.drag(app.buttons["Connect to Reviewer"], to: app.buttons["Connect from Implementer"])
        XCTAssertTrue(app.buttons["Implementer to Reviewer: Work complete"].waitForExistence(timeout: 5))
        editor.drag(app.buttons["Connect from Reviewer"], to: app.buttons["Connect from Implementer"])
        XCTAssertFalse(app.buttons["Reviewer to Implementer: Work complete"].exists)
        editor.drag(app.buttons["Connect to Implementer"], to: app.buttons["Connect to Reviewer"])
        XCTAssertFalse(app.buttons["Reviewer to Implementer: Work complete"].exists)
        editor.drag(app.buttons["Connect from Reviewer"], to: app.buttons["Connect to Implementer"])
        let link = app.buttons["Reviewer to Implementer: Work complete"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.click()
        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 5))
        XCTAssertLessThan(abs(popover.frame.midX - link.frame.midX), 350)
        editor.item("graphLinkEvent").click()
        app.menuItems["Changes requested"].click()
        app.buttons["Done"].click()
        editor.saveAndReopen()
        XCTAssertTrue(app.buttons["Implementer to Reviewer: Work complete"].exists)
        XCTAssertTrue(app.buttons["Reviewer to Implementer: Changes requested"].exists)
        XCTAssertFalse(editor.item("graphNode-task").exists)
        XCTAssertFalse(editor.item("graphNode-finish").exists)
    }

    @MainActor
    func testDecisionNodesSwitchFromAgentsAndRouteThroughSharedDragConnectors() throws {
        let app = try launchGraphDesigner()
        defer { app.terminate() }
        let editor = WorkflowGraphExampleUI(app: app, testCase: self)
        editor.item("workflowCreateOwn").click()
        editor.replace("designerName", with: "Decision routes")
        let canvas = editor.item("designerContent")
        let origin = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.45))
        origin.doubleClick()
        editor.replace("graphAgentName", with: "Router")
        editor.item("graphNodeKind").radioButtons["Decision"].click()
        XCTAssertTrue(editor.item("decisionSettings").waitForExistence(timeout: 5))
        app.buttons["Done"].click()
        for (name, vertical) in [("Builder", 0.25), ("Planner", 0.75)] {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: vertical)).doubleClick()
            editor.replace("graphAgentName", with: name)
            app.buttons["Done"].click()
        }
        editor.drag(app.buttons["Connect from Router"], to: app.buttons["Connect to Builder"])
        XCTAssertTrue(app.buttons["Router to Builder: Passthrough"].waitForExistence(timeout: 5))
        origin.click()
        XCTAssertTrue(app.staticTexts["No decision is made and Nouli is not called."].waitForExistence(timeout: 5))
        app.buttons["Done"].click()
        editor.drag(app.buttons["Connect from Router"], to: app.buttons["Connect to Planner"])
        XCTAssertTrue(app.buttons["Router to Planner: Planner"].waitForExistence(timeout: 5))
        origin.click()
        XCTAssertTrue(editor.item("decisionQuestion").waitForExistence(timeout: 5))
        editor.replace("decisionQuestion", with: "Which agent should handle the incoming work?")
        let options = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'decisionOption-'"))
        XCTAssertEqual(options.count, 2)
        XCTAssertFalse(app.textFields["When should work go here?"].exists)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Decision routing popup"
        image.lifetime = .keepAlways
        add(image)
        app.buttons["Done"].click()
        editor.saveAndReopen()
        XCTAssertTrue(app.buttons["Router to Builder: Builder"].exists)
        XCTAssertTrue(app.buttons["Router to Planner: Planner"].exists)
        editor.verifyYesNo()
        editor.verifyScore()
    }

    @MainActor
    func testAdversarialGraphCanBeEditedSavedAndReopened() throws {
        let app = try launchGraphDesigner()
        defer { app.terminate() }
        let editor = WorkflowGraphExampleUI(app: app, testCase: self)
        editor.item("workflowChoice-Adversarial").click()
        editor.item("workflowEditType").click()
        XCTAssertTrue(editor.item("graphNode-implementer").waitForExistence(timeout: 5))
        editor.item("graphNode-implementer").click()
        editor.replace("graphAgentInstructions", with: "Complete the task and address review feedback.")
        XCTAssertFalse(editor.item("graphReceive").exists)
        app.buttons["Done"].click()
        editor.saveAndReopen()
        editor.item("graphNode-implementer").click()
        XCTAssertEqual(
            editor.item("graphAgentInstructions").value as? String,
            "Complete the task and address review feedback.")
    }

    @MainActor
    func testCoordinatorGraphCanBeEditedSavedAndReopened() throws {
        let app = try launchGraphDesigner()
        defer { app.terminate() }
        let editor = WorkflowGraphExampleUI(app: app, testCase: self)
        editor.item("workflowChoice-Coordinator").click()
        editor.item("workflowEditType").click()
        for id in ["planner", "worker-1", "worker-2", "coordinator"] {
            XCTAssertTrue(editor.item("graphNode-\(id)").waitForExistence(timeout: 5))
        }
        editor.item("graphNode-coordinator").click()
        XCTAssertTrue(editor.item("graphReceive").waitForExistence(timeout: 5))
        editor.chooseOption("Start as work arrives")
        editor.chooseOption("Wait for every incoming link")
        app.buttons["Done"].click()
        editor.item("graphNode-worker-1").click()
        XCTAssertFalse(editor.item("graphReceive").exists)
        XCTAssertFalse(editor.item("graphCopies").exists)
        editor.replace("graphAgentName", with: "Builder")
        app.buttons["Done"].click()
        editor.item("graphNode-worker-1").rightClick()
        app.menuItems["Duplicate agent"].click()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Builder copy'")).firstMatch.exists)
        editor.saveAndReopen()
        editor.item("graphNode-worker-1").click()
        XCTAssertEqual(editor.item("graphAgentName").value as? String, "Builder")
    }

    @MainActor
    func testGraphNodeDragAndDeleteKeepSettingsAndTextEditingSeparate() throws {
        let app = try launchGraphDesigner()
        defer { app.terminate() }
        let editor = WorkflowGraphExampleUI(app: app, testCase: self)
        editor.item("workflowChoice-Adversarial").click()
        editor.item("workflowEditType").click()
        let node = editor.item("graphNode-implementer")
        XCTAssertTrue(node.waitForExistence(timeout: 5))
        let original = node.frame
        let start = node.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.click(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 60, dy: 45)))
        XCTAssertFalse(app.popovers.firstMatch.exists)
        XCTAssertGreaterThan(abs(node.frame.midX - original.midX), 30)
        node.click()
        XCTAssertTrue(editor.item("graphAgentName").waitForExistence(timeout: 5))
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(node.waitForNonExistence(timeout: 5), app.debugDescription)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(node.waitForExistence(timeout: 5))
        node.click()
        editor.replace("graphAgentName", with: "AB")
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertEqual(editor.item("graphAgentName").value as? String, "A")
        XCTAssertTrue(node.exists)
        app.buttons["Done"].click()
    }

    @MainActor
    func testDecisionValidationReturnsToAnOffscreenNodeRepeatedly() throws {
        let app = try launchGraphDesigner()
        defer { app.terminate() }
        let editor = WorkflowGraphExampleUI(app: app, testCase: self)
        editor.item("workflowCreateOwn").click()
        editor.replace("designerName", with: "Validation navigation")
        let canvas = editor.item("designerContent")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.25)).doubleClick()
        editor.replace("graphAgentName", with: "Router")
        editor.item("graphNodeKind").radioButtons["Decision"].click()
        app.buttons["Done"].click()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.4)).doubleClick()
        editor.replace("graphAgentName", with: "Far agent")
        app.buttons["Done"].click()
        let far = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'graphNode-' AND label CONTAINS 'Far agent'")
        )
        .firstMatch
        let start = far.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.click(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 650, dy: 0)))
        let router = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'graphNode-' AND label CONTAINS 'Router'")
        )
        .firstMatch
        for _ in 0..<2 {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.7)).scroll(byDeltaX: -2000, deltaY: 0)
            XCTAssertFalse(router.isHittable)
            editor.item("designerDecisionValidation").click()
            XCTAssertTrue(editor.item("decisionSettings").waitForExistence(timeout: 5))
            XCTAssertTrue(router.isHittable)
            XCTAssertTrue(app.staticTexts["Connect an output. One connection passes work through."].exists)
            app.buttons["Done"].click()
        }
    }

    @MainActor
    private func launchGraphDesigner() throws -> XCUIApplication {
        let folder = try makeTestFolder(prefix: "HandshakeGraphEditor")
        let app = try makeApp(lastOpenFolder: folder)
        app.launch()
        XCTAssertTrue(app.buttons["workflowCreateOwn"].waitForExistence(timeout: 10), app.debugDescription)
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1200, height: 850))
        return app
    }
}

@MainActor
private struct WorkflowGraphExampleUI {
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
    private func reveal(_ control: XCUIElement) {
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

    private func click(_ id: String) {
        let control = item(id)
        reveal(control)
        control.click()
    }

    func chooseAnswerType(_ title: String) {
        click("decisionAnswerType")
        app.menuItems[title].click()
    }

    private var router: XCUIElement {
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
