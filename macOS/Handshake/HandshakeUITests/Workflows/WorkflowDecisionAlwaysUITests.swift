import XCTest

extension HandshakeUITests {
    @MainActor
    func testAlwaysDecisionOutputsAndZoomButtonHitAreas() throws {
        let folder = try makeTestFolder(prefix: "HandshakeAlwaysOutputs")
        let app = try makeApp(lastOpenFolder: folder)
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowCreateOwn"].waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 922, height: 676))
        let editor = WorkflowGraphExampleUI(app: app, testCase: self)
        createAlwaysDecision(editor, app: app)
        verifyAlwaysAcrossAnswerTypes(editor, app: app)
        verifyGraphZoomHitAreas(app: app)
    }

    @MainActor
    private func createAlwaysDecision(_ editor: WorkflowGraphExampleUI, app: XCUIApplication) {
        editor.item("workflowCreateOwn").click()
        editor.replace("designerName", with: "Always delivery")
        let canvas = editor.item("designerContent")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.45)).doubleClick()
        editor.replace("graphAgentName", with: "Router")
        editor.item("graphNodeKind").radioButtons["Decision"].click()
        app.buttons["Done"].click()
        let targets: [(String, CGVector)] = [
            ("Builder", .init(dx: 0.6, dy: 0.2)), ("Planner", .init(dx: 0.6, dy: 0.7)),
            ("Audit one", .init(dx: 0.86, dy: 0.2)), ("Audit two", .init(dx: 0.86, dy: 0.7)),
        ]
        for (name, position) in targets {
            canvas.coordinate(withNormalizedOffset: position).doubleClick()
            editor.replace("graphAgentName", with: name)
            app.buttons["Done"].click()
            editor.drag(app.buttons["Connect from Router"], to: app.buttons["Connect to \(name)"])
        }
        editor.router.click()
        XCTAssertFalse(app.checkBoxes["Audit one"].exists)
        editor.click("decisionAlwaysEnabled")
        for name in ["Audit one", "Audit two"] {
            let checkbox = app.checkBoxes[name]
            editor.reveal(checkbox)
            checkbox.click()
        }
        app.buttons["Done"].click()
        editor.saveAndReopen()
    }

    @MainActor
    private func verifyAlwaysAcrossAnswerTypes(_ editor: WorkflowGraphExampleUI, app: XCUIApplication) {
        for answer in ["Multiple choice", "Yes/No", "Score"] {
            XCTAssertTrue(app.buttons["Router to Audit one: Always"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Router to Audit two: Always"].exists)
            editor.router.click()
            editor.chooseAnswerType(answer)
            let enabled = app.checkBoxes["decisionAlwaysEnabled"]
            XCTAssertTrue((enabled.value as? NSNumber)?.boolValue == true || enabled.value as? String == "1")
            if answer == "Multiple choice" {
                let options = app.descendants(matching: .any).matching(
                    NSPredicate(format: "identifier BEGINSWITH 'decisionOption-'"))
                XCTAssertEqual(options.count, 2)
            } else if answer == "Yes/No" {
                editor.click("decisionUncertain")
                XCTAssertTrue(app.staticTexts["Connect one agent for Uncertain."].exists)
                editor.click("decisionUncertain")
            } else {
                let image = XCTAttachment(screenshot: app.screenshot())
                image.name = "Score with optional Always destinations"
                image.lifetime = .keepAlways
                add(image)
            }
            app.buttons["Done"].click()
            editor.saveAndReopen()
        }
    }

    @MainActor
    private func verifyGraphZoomHitAreas(app: XCUIApplication) {
        let reset = app.buttons["designerZoomReset"]
        reset.click()
        let plus = app.buttons["designerZoomIn"]
        let minus = app.buttons["designerZoomOut"]
        for button in [plus, minus] {
            XCTAssertGreaterThanOrEqual(button.frame.width, 28)
            XCTAssertGreaterThanOrEqual(button.frame.height, 28)
        }
        plus.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.9)).click()
        XCTAssertEqual(reset.value as? String, "110%")
        minus.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.1)).click()
        XCTAssertEqual(reset.value as? String, "100%")
    }
}
