import AppKit
import WebKit

/// Owns one native website sheet and resolves its delegate continuation exactly once.
final class BrowserDialogs {
    private var cancelPending: (() -> Void)?

    func cancel() {
        let pending = cancelPending
        cancelPending = nil
        pending?()
    }

    func alert(_ message: String, origin: String, window: NSWindow?, completion: @escaping () -> Void) {
        let alert = makeAlert(message, origin: origin)
        present(alert, window: window) { _ in completion() }
    }

    func confirm(_ message: String, origin: String, window: NSWindow?, completion: @escaping (Bool) -> Void) {
        let alert = makeAlert(message, origin: origin)
        alert.addButton(withTitle: "Cancel")
        present(alert, window: window) { completion($0 == .alertFirstButtonReturn) }
    }

    func prompt(
        _ message: String, value: String?, origin: String, window: NSWindow?, completion: @escaping (String?) -> Void
    ) {
        let alert = makeAlert(message, origin: origin)
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(string: value ?? "")
        input.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        input.setAccessibilityIdentifier("browserPrompt")
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        present(alert, window: window) { completion($0 == .alertFirstButtonReturn ? input.stringValue : nil) }
    }

    private func makeAlert(_ message: String, origin: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = origin.isEmpty ? "Website" : origin
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        return alert
    }

    private func present(
        _ alert: NSAlert, window: NSWindow?, completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        cancel()
        guard let window, window.attachedSheet == nil else {
            completion(.cancel)
            return
        }
        var resolved = false
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard !resolved else { return }
            resolved = true
            self?.cancelPending = nil
            completion(response)
        }
        cancelPending = { [weak window] in
            window?.endSheet(alert.window, returnCode: .cancel)
            finish(.cancel)
        }
        alert.beginSheetModal(for: window, completionHandler: finish)
    }

    func files(_ parameters: WKOpenPanelParameters, window: NSWindow?, completion: @escaping ([URL]?) -> Void) {
        cancel()
        guard let window, window.attachedSheet == nil else {
            completion(nil)
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        var resolved = false
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard !resolved else { return }
            resolved = true
            self?.cancelPending = nil
            completion(response == .OK ? panel.urls : nil)
        }
        cancelPending = {
            panel.cancel(nil)
            finish(.cancel)
        }
        panel.beginSheetModal(for: window, completionHandler: finish)
    }
}
