import XCTest

extension HandshakeUITests {
    @MainActor
    func testEdgeChoicesCreateCancelAndMoveThroughUnassignedConnections() throws {
        let folder = try makeTestFolder(prefix: "HandshakeEdgeChoices")
        let app = try makeApp(lastOpenFolder: folder)
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowCreateOwn"].waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1200, height: 850))
        let editor = WorkflowGraphExampleUI(app: app, testCase: self)
        createAuthoredChoiceGraph(editor, app: app)
        cancelNewEdgeChoice(editor, app: app, label: "Router to Audit: Always", escape: false)
        cancelNewEdgeChoice(editor, app: app, label: "Router to Builder: Small change", escape: true)
        chooseEdgeOutput(editor, app: app, label: "Router to Audit: Always", output: "Unassigned")
        beginNewEdgeChoice(editor, app: app, label: "Router to Audit: Unassigned")
        editor.replace("decisionNewChoiceText", with: "Needs audit")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.popovers.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Router to Audit: Needs audit"].exists)
        chooseEdgeOutput(editor, app: app, label: "Router to Audit: Needs audit", output: "Unassigned")
        XCTAssertTrue(app.buttons["Router to Audit: Unassigned"].exists)
        chooseEdgeOutput(editor, app: app, label: "Router to Audit: Unassigned", output: "Small change")
        XCTAssertTrue(app.buttons["Router to Builder: Unassigned"].exists)
        XCTAssertTrue(app.buttons["Router to Audit: Small change"].exists)
        chooseEdgeOutput(editor, app: app, label: "Router to Builder: Unassigned", output: "Needs audit")
        editor.saveAndReopen()
        XCTAssertTrue(app.buttons["Router to Builder: Needs audit"].exists)
        XCTAssertTrue(app.buttons["Router to Audit: Small change"].exists)
        XCTAssertTrue(app.buttons["Router to Planner: Large change"].exists)
    }

    @MainActor
    private func beginNewEdgeChoice(_ editor: WorkflowGraphExampleUI, app: XCUIApplication, label: String) {
        app.buttons[label].click()
        editor.item("decisionEdgeOutput").click()
        app.menuItems["New choice…"].click()
        XCTAssertTrue(editor.item("decisionNewChoiceText").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Delete link"].exists)
        XCTAssertFalse(app.buttons["Create choice"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "decisionCancelNewChoice").count, 1)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == 'Done'")).count, 1)
    }

    @MainActor
    private func cancelNewEdgeChoice(
        _ editor: WorkflowGraphExampleUI, app: XCUIApplication, label: String, escape: Bool
    ) {
        beginNewEdgeChoice(editor, app: app, label: label)
        editor.replace("decisionNewChoiceText", with: "Discarded draft")
        if escape {
            app.typeKey(.escape, modifierFlags: [])
        } else {
            editor.item("decisionCancelNewChoice").click()
        }
        XCTAssertTrue(app.popovers.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons[label].exists)
    }

    @MainActor
    private func chooseEdgeOutput(
        _ editor: WorkflowGraphExampleUI, app: XCUIApplication, label: String, output: String
    ) {
        app.buttons[label].click()
        editor.item("decisionEdgeOutput").click()
        app.menuItems[output].click()
        app.buttons["Done"].click()
    }

    @MainActor
    func testChoiceOptionsMapToAgentsAndEdgeMenuIncludesAlways() throws {
        let folder = try makeTestFolder(prefix: "HandshakeChoiceOptions")
        let app = try makeApp(lastOpenFolder: folder)
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowCreateOwn"].waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1200, height: 850))
        let editor = WorkflowGraphExampleUI(app: app, testCase: self)
        createAuthoredChoiceGraph(editor, app: app)
        verifyChoiceDestinationsAndEdgeOutputs(editor, app: app)
        let planner = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'graphNode-' AND label CONTAINS 'Planner'")
        ).firstMatch
        planner.click()
        editor.replace("graphAgentName", with: "Generalist")
        app.buttons["Done"].click()
        editor.saveAndReopen()
        XCTAssertTrue(app.buttons["Router to Generalist: Large change"].exists)
        XCTAssertTrue(app.buttons["Router to Audit: Small change"].exists)
        XCTAssertTrue(app.buttons["Router to Builder: Always"].exists)
    }

    @MainActor
    private func createAuthoredChoiceGraph(_ editor: WorkflowGraphExampleUI, app: XCUIApplication) {
        editor.item("workflowCreateOwn").click()
        editor.replace("designerName", with: "Authored choices")
        let canvas = editor.item("designerContent")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.45)).doubleClick()
        editor.replace("graphAgentName", with: "Router")
        editor.verifyDisclosureRow("agentAdvanced")
        editor.item("graphNodeKind").radioButtons["Decision"].click()
        let texts = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH 'decisionOptionText-'"))
        XCTAssertEqual(texts.count, 2)
        editor.replace(texts.element(boundBy: 0).identifier, with: "Small change")
        editor.replace(texts.element(boundBy: 1).identifier, with: "Large change")
        app.buttons["Done"].click()
        let targets: [(String, CGVector)] = [
            ("Builder", .init(dx: 0.6, dy: 0.2)), ("Planner", .init(dx: 0.6, dy: 0.7)),
            ("Audit", .init(dx: 0.86, dy: 0.2)),
        ]
        for (name, point) in targets {
            canvas.coordinate(withNormalizedOffset: point).doubleClick()
            editor.replace("graphAgentName", with: name)
            app.buttons["Done"].click()
            editor.drag(app.buttons["Connect from Router"], to: app.buttons["Connect to \(name)"])
        }
        app.buttons["Router to Audit: Unassigned"].click()
        editor.item("decisionEdgeOutput").click()
        XCTAssertTrue(app.menuItems["Small change"].exists)
        XCTAssertTrue(app.menuItems["Large change"].exists)
        app.menuItems["Always"].click()
        app.buttons["Done"].click()
        editor.saveAndReopen()
    }

    @MainActor
    private func verifyChoiceDestinationsAndEdgeOutputs(_ editor: WorkflowGraphExampleUI, app: XCUIApplication) {
        editor.router.click()
        let destinations = app.popUpButtons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'decisionOptionDestination-'"))
        XCTAssertEqual(destinations.count, 2)
        destinations.element(boundBy: 0).click()
        app.menuItems["Planner"].click()
        app.buttons["Done"].click()
        XCTAssertTrue(app.buttons["Router to Planner: Small change"].exists)
        XCTAssertTrue(app.buttons["Router to Builder: Large change"].exists)
        app.buttons["Router to Builder: Large change"].click()
        editor.item("decisionEdgeOutput").click()
        app.menuItems["Small change"].click()
        app.buttons["Done"].click()
        XCTAssertTrue(app.buttons["Router to Builder: Small change"].exists)
        XCTAssertTrue(app.buttons["Router to Planner: Large change"].exists)
        app.buttons["Router to Audit: Always"].click()
        editor.item("decisionEdgeOutput").click()
        app.menuItems["Small change"].click()
        app.buttons["Done"].click()
        XCTAssertTrue(app.buttons["Router to Builder: Always"].exists)
        XCTAssertTrue(app.buttons["Router to Audit: Small change"].exists)
        editor.router.click()
        let firstText = app.textFields.matching(
            NSPredicate(format: "identifier BEGINSWITH 'decisionOptionText-'")
        )
        .element(boundBy: 0)
        XCTAssertTrue(firstText.waitForExistence(timeout: 5))
        editor.reveal(firstText)
        firstText.click()
        XCTAssertEqual(firstText.value as? String, "Small change")
        let capture = XCTAttachment(screenshot: app.popovers.firstMatch.screenshot())
        capture.name = "Authored option text and agent destination dropdowns"
        capture.lifetime = .keepAlways
        add(capture)
        app.buttons["Done"].click()
    }
}
