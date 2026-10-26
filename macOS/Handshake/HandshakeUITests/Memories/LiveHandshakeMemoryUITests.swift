import SQLite3
import XCTest

extension HandshakeUITests {
    /// Explicit opt-in: two ordinary questions through Handshake's real native agent launch UI.
    @MainActor
    func testLiveHandshakeMemoryRecallThroughBothAgentLaunchers() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HANDSHAKE_LIVE_MEMORY_UX"] == "1",
            let folderPath = environment["HANDSHAKE_LIVE_MEMORY_FOLDER"],
            let storePath = environment["HANDSHAKE_LIVE_MEMORY_STORE"],
            let home = environment["HANDSHAKE_LIVE_USER_HOME"],
            (Int(environment["HANDSHAKE_LIVE_QUOTA_REMAINING"] ?? "") ?? 0) >= 10
        else { throw XCTSkip("Live native memory UX requires an explicit trial and quota preflight.") }
        let selected = environment["HANDSHAKE_LIVE_MEMORY_HARNESSES"]?.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let cases = [
            NativeMemoryQuestion(
                "claudeCode", "Claude Code",
                "Which deployment lane should I use for this project? Answer in one sentence. Do not edit files.",
                "green"
            ),
            NativeMemoryQuestion(
                "codex", "Codex",
                "Which demo account code should I use for this project? Answer in one sentence. Do not edit files.",
                "maple-417"
            ),
        ]
        let questions = cases.filter { selected?.contains($0.harness) != false }
        guard !questions.isEmpty, selected?.allSatisfy({ name in cases.contains { $0.harness == name } }) != false
        else {
            XCTFail("HANDSHAKE_LIVE_MEMORY_HARNESSES must select claudeCode, codex, or both.")
            return
        }
        // A fresh application database and terminal set for each harness prevents old output
        // or responses from satisfying the next harness's readiness or answer expectation.
        for question in questions {
            let app = try makeApp(lastOpenFolder: URL(filePath: folderPath))
            app.launchEnvironment["HANDSHAKE_MEMORY_DIRECTORY"] = storePath
            app.launchEnvironment["HOME"] = home
            app.launchEnvironment["SHELL"] = "/bin/bash"
            app.launchEnvironment["HANDSHAKE_HARNESS_PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            let database = try XCTUnwrap(app.launchEnvironment["HANDSHAKE_DATA_DIRECTORY"])
            app.launch()
            defer { app.terminate() }
            resizeWindow(app.windows.firstMatch, to: CGSize(width: 1100, height: 800))
            openHandshakeMemory(in: app)
            XCTAssertFalse(app.staticTexts["handshakeMemoryFailure"].exists)
            app.typeKey(.escape, modifierFlags: [])
            try checkLiveRecall(
                question, app: app, data: URL(filePath: database))
        }
    }

    @MainActor
    private func checkLiveRecall(
        _ question: NativeMemoryQuestion, app: XCUIApplication, data: URL
    ) throws {
        let (title, prompt, expected) = (question.title, question.prompt, question.expected)
        let initialOutput = memoryTerminalText(data).count
        try launchLiveMemoryAgent(question, app: app, data: data)
        let ready = expectation(
            for: NSPredicate { _, _ in
                let text = String(memoryTerminalText(data).dropFirst(initialOutput))
                return text.lowercased().contains("trust") || text.contains("❯") || text.contains("›")
            }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 25), .completed, memoryTerminalText(data))
        let terminal = String(memoryTerminalText(data).dropFirst(initialOutput)).lowercased()
            .filter { !$0.isWhitespace }
        let asksTrust =
            terminal.contains("trustthisfolder") || terminal.contains("trustthefiles")
            || terminal.contains("trustthisdirectory") || terminal.contains("doyoutrust")
        if asksTrust {
            let trustOutput = memoryTerminalText(data).count
            if terminal.contains("no,exit") { app.typeKey(.downArrow, modifierFlags: []) }
            app.typeKey(.return, modifierFlags: [])
            let freshPrompt = expectation(
                for: NSPredicate { _, _ in
                    let text = String(memoryTerminalText(data).dropFirst(trustOutput))
                    return text.contains("❯") || text.contains("›")
                }, evaluatedWith: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [freshPrompt], timeout: 25), .completed, memoryTerminalText(data))
        }
        app.typeText(prompt + "\r")
        let answered = expectation(
            for: NSPredicate { _, _ in
                memoryResponses(data.appending(path: "twine.db")).contains {
                    $0.localizedCaseInsensitiveContains(expected)
                }
            }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [answered], timeout: 90), .completed, memoryTerminalText(data))
        XCTAssertTrue(memoryTerminalText(data).localizedCaseInsensitiveContains(expected))
        let responses = memoryResponses(data.appending(path: "twine.db"))
        let answer = try XCTUnwrap(responses.last { $0.localizedCaseInsensitiveContains(expected) })
        attachLiveMemoryEvidence(title: title, prompt: prompt, answer: answer, app: app)
        app.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Cancelled"].waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor
    private func launchLiveMemoryAgent(
        _ question: NativeMemoryQuestion, app: XCUIApplication, data: URL
    ) throws {
        let (harness, title) = (question.harness, question.title)
        let menu = app.descendants(matching: .any).matching(identifier: "workflowChoice-Single agent").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), app.debugDescription)
        menu.click()
        let item = app.menuItems[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), app.debugDescription)
        item.click()
        let model = app.menuItems["harness-\(harness)"].menuItems["Default model"]
        XCTAssertTrue(model.waitForExistence(timeout: 10), app.debugDescription)
        model.click()
        let effort = model.menuItems["Default effort"].firstMatch
        if effort.waitForExistence(timeout: 2) { effort.click() }
        let database = data.appending(path: "twine.db")
        let query = "SELECT harness_id FROM workflows WHERE kind = 'single_agent' ORDER BY id DESC LIMIT 1"
        let launched = expectation(
            for: NSPredicate { _, _ in !memoryDatabaseValues(database, query: query).isEmpty }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [launched], timeout: 10), .completed)
        let actual = try XCTUnwrap(memoryDatabaseValues(database, query: query).first)
        let expected = harness == "claudeCode" ? "claude_code" : harness
        guard actual == expected else {
            throw NSError(
                domain: "LiveMemoryUX", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Refusing a model question: selected \(harness), launched \(actual)."
                ])
        }
    }

    @MainActor
    private func attachLiveMemoryEvidence(title: String, prompt: String, answer: String, app: XCUIApplication) {
        let evidence = XCTAttachment(string: "Harness: \(title)\nQuestion: \(prompt)\n\(answer)")
        evidence.name = "Native recall through Handshake — \(title)"
        evidence.lifetime = .keepAlways
        add(evidence)
        attachScreenshot(of: app, named: "Native Handshake memory recall — \(title)")
    }

}

private func memoryResponses(_ path: URL) -> [String] {
    memoryDatabaseValues(
        path, query: "SELECT message FROM trace_events WHERE message LIKE 'Finished responding%' ORDER BY id")
}

private func memoryDatabaseValues(_ path: URL, query: String) -> [String] {
    var database: OpaquePointer?
    guard sqlite3_open_v2(path.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        sqlite3_close(database)
        return []
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard
        sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK
    else { return [] }
    defer { sqlite3_finalize(statement) }
    var values: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        if let text = sqlite3_column_text(statement, 0) { values.append(String(cString: text)) }
    }
    return values
}

private func memoryTerminalText(_ directory: URL) -> String {
    guard
        let files = FileManager.default.enumerator(
            at: directory.appending(path: "transcripts"), includingPropertiesForKeys: nil)
    else { return "" }
    let bytes = files.compactMap { $0 as? URL }.filter { $0.pathExtension == "bytes" }.sorted { $0.path < $1.path }
        .compactMap { try? Data(contentsOf: $0) }.reduce(into: Data()) { $0.append($1) }
    return (String(bytes: bytes, encoding: .utf8) ?? "")
        .replacingOccurrences(of: "\u{1B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
}

private struct NativeMemoryQuestion {
    let harness: String
    let title: String
    let prompt: String
    let expected: String

    init(_ harness: String, _ title: String, _ prompt: String, _ expected: String) {
        self.harness = harness
        self.title = title
        self.prompt = prompt
        self.expected = expected
    }
}
