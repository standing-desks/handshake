import AppKit
import Testing
import WebKit

@testable import Handshake

@MainActor
struct BrowserInteractionTests {
    @Test func nativeDropdownModifiersAndNestedDocuments() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = BrowserTab(configuration: configuration, automation: true)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 800), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.contentView = tab.webView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(tab.webView)
        tab.isVisible = true
        tab.webView.pageZoom = 1.25
        defer {
            tab.close()
            window.orderOut(nil)
        }
        tab.webView.loadHTMLString(BrowserInteractionFixture.html, baseURL: URL(string: "https://example.test"))
        try await waitUntil { tab.pageTitle == "Interactions" && !tab.isLoading }
        let driver = BrowserAutomationDriver(tab: tab)
        _ = try await driver.execute(.init(action: "wait", text: "Frame ready"))
        let dropdown = try await reference("Plan", driver: driver)
        _ = try await driver.execute(.init(action: "select", element: dropdown, value: "pro"))
        _ = try await driver.execute(.init(action: "wait", text: "plan:pro:true"))
        await #expect(throws: (any Error).self) {
            _ = try await driver.execute(.init(action: "click", element: dropdown))
        }
        await #expect(throws: (any Error).self) {
            _ = try await driver.execute(.init(action: "press", key: "ArrowDown"))
        }
        // Hover requires key-window ownership, exercised by the desktop UI suite.
        try await verifyRedirectedFocus(driver, tab: tab)
        try await verifyDisabledControls(driver, tab: tab)
        try await shadowAndFrame(driver, tab: tab)
    }

    private func verifyRedirectedFocus(_ driver: BrowserAutomationDriver, tab: BrowserTab) async throws {
        _ = try await tab.webView.evaluateJavaScript(
            """
            const trap=document.createElement('input'); trap.id='trap'; document.body.append(trap);
            plan.addEventListener('focus',()=>trap.focus()); trap.focus();
            """)
        await #expect(throws: (any Error).self) {
            let plan = try await reference("Plan", driver: driver)
            _ = try await driver.execute(.init(action: "select", element: plan, value: "free"))
        }
        #expect(try await tab.webView.evaluateJavaScript("trap.value") as? String == "")
    }

    private func verifyDisabledControls(_ driver: BrowserAutomationDriver, tab: BrowserTab) async throws {
        _ = try await tab.webView.evaluateJavaScript(
            """
            const fieldset=document.createElement('fieldset'); fieldset.disabled=true;
            fieldset.innerHTML='<input aria-label="Disabled field">'+
                '<select aria-label="Disabled plan"><option>Free</option></select>';
            document.body.append(fieldset);
            """)
        for name in ["Disabled field", "Disabled plan"] {
            let id = try await reference(name, driver: driver)
            let state = try await tab.webView.callAsyncJavaScript(
                "return handshakeBrowser.state({id,state:'enabled'})",
                arguments: ["id": id], in: nil, contentWorld: .defaultClient)
            #expect(state as? Bool == false)
            await #expect(throws: (any Error).self) {
                _ = try await driver.execute(.init(action: "click", element: id))
            }
        }
    }

    private func shadowAndFrame(_ driver: BrowserAutomationDriver, tab: BrowserTab) async throws {
        let shadow = try await reference("Shadow note", driver: driver)
        _ = try await driver.execute(.init(action: "fill", element: shadow, text: "draft"))
        _ = try await driver.execute(.init(action: "press", key: "Meta+Shift+ArrowLeft"))
        _ = try await driver.execute(.init(action: "press", key: "Shift+z"))
        _ = try await driver.execute(
            .init(action: "click", element: try await reference("Save shadow", driver: driver)))
        _ = try await driver.execute(.init(action: "wait", text: "shadow:Z:true"))
        let child = try await reference("Frame note", driver: driver)
        _ = try await driver.execute(.init(action: "fill", element: child, text: "Nested"))
        _ = try await driver.execute(.init(action: "click", element: try await reference("Save frame", driver: driver)))
        _ = try await driver.execute(.init(action: "wait", text: "frame:Nested:true"))
        _ = try await tab.webView.evaluateJavaScript("document.querySelector('iframe').srcdoc='<p>Replaced frame</p>'")
        _ = try await driver.execute(.init(action: "wait", text: "Replaced frame"))
        await #expect(throws: (any Error).self) {
            _ = try await driver.execute(.init(action: "fill", element: child, text: "Wrong document"))
        }
        _ = try await driver.execute(.init(action: "wait_url", text: "example.test"))
        _ = try await driver.execute(.init(action: "wait_load"))
        _ = try await driver.execute(.init(action: "wait_element", element: shadow, state: "enabled"))
    }

    private func reference(_ name: String, driver: BrowserAutomationDriver) async throws -> String {
        let result = try await driver.execute(.init(action: "snapshot"))
        let snapshot = try JSONSerialization.jsonObject(with: Data(try #require(result.content).utf8)) as? [String: Any]
        let elements = try #require(snapshot?["elements"] as? [[String: Any]])
        return try #require(elements.first { $0["name"] as? String == name }?["ref"] as? String)
    }

    @Test func editingKeysDoNotAdmitApplicationShortcuts() throws {
        #expect(try BrowserKey("t").code == 17)
        #expect(try BrowserKey("y").code == 16)
        #expect(try BrowserKey("Meta+ArrowLeft").modifiers == .command)
        #expect(try BrowserKey("Shift+Tab").modifiers == .shift)
        #expect(try BrowserKey("Alt+ArrowLeft").modifiers == .option)
        for key in [
            "Meta+a", "Meta+z", "Meta+w", "Meta+q", "Meta+l", "Meta+v", "Meta+Shift+a", "Control+c", "Shift+Shift+a",
            "NoSuchKey",
        ] {
            #expect(throws: (any Error).self) { _ = try BrowserKey(key) }
        }
    }

}
