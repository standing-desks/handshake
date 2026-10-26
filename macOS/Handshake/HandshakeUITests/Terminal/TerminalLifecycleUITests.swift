import Darwin
import XCTest

extension HandshakeUITests {
    @MainActor
    func testQuitStopsShellAndDescendant() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "HandshakeUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: folder)
        }
        let app = try makeApp(lastOpenFolder: folder)
        app.launch()
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))

        let shellFile = folder.appending(path: "shell.pid")
        let descendantFile = folder.appending(path: "descendant.pid")
        defer {
            for file in [shellFile, descendantFile] {
                if let processID = readProcessID(in: file), processExists(processID) {
                    _ = kill(processID, SIGKILL)
                }
            }
        }

        // Replace the user's login shell so the commands below work with fish, zsh, and bash.
        app.typeText("exec /bin/sh\r")
        app.typeText("echo $$ > shell.pid\r")
        let shellID = try waitForProcessID(in: shellFile)
        app.typeText("trap '' HUP; (trap '' HUP; while :; do sleep 1; done) & echo $! > descendant.pid\r")
        let descendantID = try waitForProcessID(in: descendantFile)

        app.menuBars.menuBarItems["Handshake"].click()
        app.menuItems["Quit Handshake"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        XCTAssertTrue(waitForProcessExit(shellID), "shell survived app quit")
        XCTAssertTrue(waitForProcessExit(descendantID), "descendant survived app quit")
    }

    @MainActor
    private func waitForProcessID(in file: URL) throws -> pid_t {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let processID = readProcessID(in: file) {
                return processID
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return try XCTUnwrap(readProcessID(in: file), "Timed out waiting for a PID in \(file.path)")
    }

    private func readProcessID(in file: URL) -> pid_t? {
        guard
            let contents = try? String(contentsOf: file, encoding: .utf8),
            let processID = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)),
            processID > 0
        else { return nil }
        return processID
    }

    private func waitForProcessExit(_ processID: pid_t) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while processExists(processID) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        return !processExists(processID)
    }

    private func processExists(_ processID: pid_t) -> Bool {
        kill(processID, 0) == 0 || errno != ESRCH
    }
}
