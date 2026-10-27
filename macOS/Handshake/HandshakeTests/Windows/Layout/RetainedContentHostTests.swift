import AppKit
import Testing

@testable import Handshake

@MainActor
struct RetainedContentHostTests {
    @Test func deferredNativeContentCannotStealSearchFocus() async throws {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
            defer: false)
        let root = NSView(frame: window.contentLayoutRect)
        let search = NSTextView(frame: CGRect(x: 0, y: 350, width: 400, height: 30))
        let document = NSTextView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        let host = RetainedContentHost(content: document, responder: document)
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 300)
        root.addSubview(search)
        root.addSubview(host)
        window.contentView = root
        #expect(window.makeFirstResponder(search))
        host.allowsKeyboardFocus = false
        host.setVisible(true)
        host.requestKeyboardFocus()
        try await Task.sleep(for: .milliseconds(30))
        #expect(window.firstResponder === search)
        host.allowsKeyboardFocus = true
        host.requestKeyboardFocus()
        try await Task.sleep(for: .milliseconds(30))
        #expect(window.firstResponder === document)
        host.setVisible(false)
        for _ in 0..<100 {
            if document.isHidden { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(document.isHidden)
        #expect(window.firstResponder !== document)
    }
}
