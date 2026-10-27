import AppKit
import Testing
import WebKit

@testable import Handshake

@MainActor
struct BrowserDialogWebKitTests {
    @Test func nativeWebsiteSheetsReturnAcceptedAndCancelledValues() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = BrowserTab(configuration: configuration)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.contentView = tab.webView
        window.makeKeyAndOrderFront(nil)
        tab.isVisible = true
        defer {
            tab.close()
            window.orderOut(nil)
        }
        tab.load(try #require(URL(string: "about:blank")))
        try await waitUntil { tab.webView.url != nil && !tab.isLoading }
        let cases: [SheetCase] = [
            .init(script: "alert('Native alert');true"),
            .init(script: "confirm('Accept confirmation')"),
            .init(script: "!confirm('Cancel confirmation')", accepts: false),
            .init(script: "prompt('Enter text','default') === 'typed value'", text: "typed value"),
            .init(script: "prompt('Cancel input','default') === null", accepts: false),
        ]
        for testCase in cases {
            let result = Task { try await tab.webView.evaluateJavaScript(testCase.script) as? Bool }
            try await waitUntil { window.attachedSheet != nil }
            let sheet = try #require(window.attachedSheet)
            let content = try #require(sheet.contentView)
            #expect(tab.hasNativeSheet)
            #expect(sheet.sheetParent === window)
            if let text = testCase.text {
                let input = try #require(editableField(in: content))
                #expect(input.stringValue == "default")
                input.currentEditor()?.string = text
                input.stringValue = text
            }
            let action = try #require(
                button(in: content, title: testCase.accepts ? "OK" : "Cancel"))
            action.performClick(nil)
            #expect(try await result.value == true)
            try await waitUntil { window.attachedSheet == nil && !tab.hasNativeSheet }
        }
    }

    private struct SheetCase {
        let script: String
        var accepts = true
        var text: String?
    }

    private func button(in view: NSView, title: String) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        for child in view.subviews { if let result = button(in: child, title: title) { return result } }
        return nil
    }
    private func editableField(in view: NSView) -> NSTextField? {
        if let input = view as? NSTextField, input.isEditable { return input }
        for child in view.subviews { if let result = editableField(in: child) { return result } }
        return nil
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Timed out waiting for native website sheet")
        throw SheetTimeout.expired
    }
    private enum SheetTimeout: Error { case expired }
}
