import AppKit
import XCTest

extension HandshakeUITests {
    @MainActor
    func testTerminalRenderingRemainsUsableAcrossZoomAndResize() throws {
        let folder = try makeTestFolder(prefix: "HandshakeRendering")
        let fixture = """
            Terminal rendering: Hello 0123456789 README.md
            ┌────────────────────────────────────────────┐
            │ Thin borders, Unicode: café é 中文 😀       │
            └────────────────────────────────────────────┘
            Powerline:    
            """
        try fixture.write(to: folder.appending(path: "render.txt"), atomically: true, encoding: .utf8)
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["SHELL"] = "/bin/bash"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
        app.buttons["workflowChoice-Terminal"].click()
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1001, height: 701))
        app.typeText(
            "clear; cat render.txt; printf '\\033[31mRED \\033[32mGREEN \\033[0m\\n'; printf ready > rendered\r")
        waitForFile(folder.appending(path: "rendered"), containing: "ready", in: app)
        app.typeKey("0", modifierFlags: .command)
        for percent in [100, 110, 125] {
            if percent != 100 { app.typeKey("=", modifierFlags: .command) }
            app.typeText("stty size > size-\(percent)\r")
            waitForFile(folder.appending(path: "size-\(percent)"), containing: " ", in: app)
            attachScreenshot(of: app, named: "Terminal glyphs and borders at \(percent) percent")
        }
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 927, height: 663))
        app.typeText("printf 'input-survives-resize' > input-result\r")
        waitForFile(folder.appending(path: "input-result"), containing: "input-survives-resize", in: app)
        app.typeKey("0", modifierFlags: .command)
        app.typeText("cat render.txt; printf 'restored' > zoom-result\r")
        waitForFile(folder.appending(path: "zoom-result"), containing: "restored", in: app)
        attachScreenshot(of: app, named: "Terminal after resize and zoom reset")
    }
}
