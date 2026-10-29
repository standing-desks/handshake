import AppKit
import WebKit

@MainActor
struct BrowserNativeInput {
    let tab: BrowserTab

    func hover(_ point: BrowserPoint) throws {
        let view = try contentView()
        let position = tab.webView.convert(
            NSPoint(x: point.horizontal * tab.webView.pageZoom, y: point.vertical * tab.webView.pageZoom), to: nil)
        guard
            let event = NSEvent.mouseEvent(
                with: .mouseMoved, location: position, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
            )
        else { throw BrowserAutomationError.unavailable("Native hover is unavailable.") }
        // WebKit's ordinary mouseMoved responder does not deliver synthetic hover.
        // Keep this optional testing entry point behind the browser-control beta flag.
        let selector = NSSelectorFromString("_simulateMouseMove:")
        guard view.responds(to: selector), view.window?.isKeyWindow == true else {
            throw BrowserAutomationError.unavailable(
                "Native hover requires a focused browser window and supported WebKit.")
        }
        view.perform(selector, with: event)
    }

    func press(_ value: String) throws {
        let key = try BrowserKey(value)
        let view = try contentView()
        guard view.window?.makeFirstResponder(view) == true else {
            throw BrowserAutomationError.unavailable("The browser could not receive keyboard focus.")
        }
        for type: NSEvent.EventType in [.keyDown, .keyUp] {
            guard
                let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: key.modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0,
                    context: nil, characters: key.characters, charactersIgnoringModifiers: key.characters.lowercased(),
                    isARepeat: false, keyCode: key.code
                )
            else { throw BrowserAutomationError.unavailable("Native key input is unavailable.") }
            if type == .keyDown { view.keyDown(with: event) } else { view.keyUp(with: event) }
        }
    }

    private func contentView() throws -> NSView {
        guard tab.isVisible, !tab.isClosed, !tab.isLoading, !tab.hasNativeSheet, tab.webView.window != nil else {
            throw BrowserAutomationError.unavailable(
                "Select the browser tab and dismiss any dialog before using input.")
        }
        func find(_ view: NSView) -> NSView? {
            if view is any NSTextInputClient { return view }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        guard let view = find(tab.webView) else {
            throw BrowserAutomationError.unavailable("Native browser input is unavailable.")
        }
        return view
    }

    func click(_ point: BrowserPoint) throws {
        let view = try contentView()
        let scale = tab.webView.pageZoom
        let position = tab.webView.convert(NSPoint(x: point.horizontal * scale, y: point.vertical * scale), to: nil)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            guard
                let event = NSEvent.mouseEvent(
                    with: type, location: position, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: 1)
            else { continue }
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
    }

    func insert(_ text: String) throws {
        guard let input = try contentView() as? any NSTextInputClient else { return }
        input.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

}

struct BrowserPoint: Decodable {
    let horizontal: Double
    let vertical: Double
    enum CodingKeys: String, CodingKey {
        case horizontal = "x"
        case vertical = "y"
    }
}
