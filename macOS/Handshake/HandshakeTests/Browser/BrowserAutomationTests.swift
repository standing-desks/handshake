import AppKit
import Testing
import WebKit

@testable import Handshake

@MainActor
struct BrowserAutomationTests {
    @Test func nativeInputSnapshotsAndNavigationInvalidateReferences() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        BrowserAutomationDriver.configure(configuration)
        let tab = BrowserTab(configuration: configuration, automation: true)
        #expect(configuration.userContentController.userScripts.count == 2)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.contentView = tab.webView
        window.makeKeyAndOrderFront(nil)
        tab.isVisible = true
        tab.webView.pageZoom = 1.25
        defer {
            tab.close()
            window.orderOut(nil)
        }
        tab.webView.loadHTMLString(Self.fixture, baseURL: URL(string: "https://example.test"))
        try await loaded(tab, title: "Automation fixture")
        let driver = BrowserAutomationDriver(tab: tab)
        let input = try await reference("Email", driver: driver)
        let button = try await reference("Save", driver: driver)
        _ = try await driver.execute(.init(action: "fill", element: input, text: "native@example.test"))
        _ = try await driver.execute(.init(action: "click", element: button))
        _ = try await driver.execute(.init(action: "wait", text: "native@example.test:true"))
        #expect(try await tab.webView.evaluateJavaScript("window.trustedInput") as? Bool == true)
        let console = try await driver.execute(.init(action: "console"))
        #expect(console.content?.contains("[object]") == true)
        let capture = try await driver.execute(.init(action: "screenshot"))
        let png = try #require(capture.png)
        #expect(Data(base64Encoded: png)?.prefix(4) == Data([137, 80, 78, 71]))
        try await detachedReference(tab, driver: driver, previous: button)
        try await boundedReferences(tab)
        tab.webView.loadHTMLString("<title>Replacement</title><button>Other</button>", baseURL: nil)
        try await loaded(tab, title: "Replacement")
        await #expect(throws: (any Error).self) {
            _ = try await driver.execute(.init(action: "click", element: button))
        }
    }

    private func detachedReference(_ tab: BrowserTab, driver: BrowserAutomationDriver, previous: String) async throws {
        _ = try await tab.webView.evaluateJavaScript("window.removed=document.querySelector('button');removed.remove()")
        _ = try await driver.execute(.init(action: "snapshot"))
        _ = try await tab.webView.evaluateJavaScript("document.body.append(removed)")
        let current = try await reference("Save", driver: driver)
        #expect(current != previous)
        await #expect(throws: (any Error).self) {
            _ = try await driver.execute(.init(action: "click", element: previous))
        }
        _ = try await driver.execute(.init(action: "click", element: current))
    }

    private func boundedReferences(_ tab: BrowserTab) async throws {
        let result = try await tab.webView.callAsyncJavaScript(
            """
            const nodes = Array.from({length:1000}, (_, i) => {
                const node=document.createElement('button'); node.textContent='Item '+i; return node;
            });
            document.body.replaceChildren(...nodes);
            for (let offset=0; offset<1000; offset+=100) {
                nodes.forEach((node,i) => node.style.display=i>=offset && i<offset+100 ? '' : 'none');
                handshakeBrowser.snapshot();
            }
            nodes.forEach((node,i) => node.style.display=i===0 ? '' : 'none');
            const fresh=document.createElement('button'); fresh.textContent='New'; document.body.append(fresh);
            const snapshot=handshakeBrowser.snapshot();
            for (const element of snapshot.elements) handshakeBrowser.target({id:element.ref,fill:false});
            return snapshot.elements.length===2;
            """, arguments: [:], in: nil, contentWorld: .defaultClient)
        #expect(result as? Bool == true)
    }

    private func reference(_ name: String, driver: BrowserAutomationDriver) async throws -> String {
        let snapshot = try await driver.execute(.init(action: "snapshot"))
        let content = try #require(snapshot.content)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        let elements = try #require(object["elements"] as? [[String: Any]])
        return try #require(elements.first { $0["name"] as? String == name }?["ref"] as? String)
    }

    private func loaded(_ tab: BrowserTab, title: String) async throws {
        for _ in 0..<200 {
            if tab.pageTitle == title && !tab.isLoading { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Fixture did not load")
    }

    private static let fixture = """
        <title>Automation fixture</title><div style="height:1000px">Above the form</div>
        <input type="email" aria-label="Email" value="previous@example.test">
        <button>Save</button><p></p><div style="height:1000px">Below the form</div>
        <script>
        document.querySelector('input').addEventListener('input', e => window.trustedInput=e.isTrusted);
        document.querySelector('button').addEventListener('click', e => {
            document.querySelector('p').textContent=document.querySelector('input').value+':'+e.isTrusted;
        });
        console.log(Object.create(null));
        </script>
        """
}
