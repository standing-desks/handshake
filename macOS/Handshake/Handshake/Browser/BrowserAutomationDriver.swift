import AppKit
import WebKit

enum BrowserAutomationError: Error, LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        }
    }
}

/// Executes bounded operations on the visible native page; never controls the desktop pointer.
@MainActor
struct BrowserAutomationDriver {
    let tab: BrowserTab

    static func requiresVisiblePage(_ action: BrowserAction) -> Bool {
        ["click", "fill", "hover", "press", "select", "screenshot"].contains(action.action)
    }

    static func configure(_ configuration: WKWebViewConfiguration) {
        guard let url = Bundle.main.url(forResource: "BrowserAutomation", withExtension: "js"),
            let script = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        add(script, to: configuration, world: .defaultClient)
        add(consoleScript, to: configuration, world: .page)
    }

    private static func add(_ script: String, to configuration: WKWebViewConfiguration, world: WKContentWorld) {
        let installed = configuration.userContentController.userScripts.contains { $0.source == script }
        if !installed {
            configuration.userContentController.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        }
    }

    private static let consoleScript = """
        (() => {
            if (globalThis.__handshakeConsole) return;
            const entries = []; globalThis.__handshakeConsole = entries;
            const safe = value => value !== null && ['object','function'].includes(typeof value)
                ? '[object]' : String(value);
            const add = (level, text) => {
                entries.push({level, text:safe(text).slice(0,1000)});
                if(entries.length>100) entries.shift();
            };
            for (const level of ['log','warn','error']) {
                const original = console[level].bind(console);
                console[level] = (...args) => {
                    try { add(level,args.map(safe).join(' ')); } catch {}
                    return original(...args);
                };
            }
            addEventListener('error', e => add('error', e.message));
            addEventListener('unhandledrejection', e => add('error', e.reason));
        })();
        """

    func execute(_ action: BrowserAction) async throws -> BrowserControlResult {
        try Task.checkCancellation()
        switch action.action {
        case "navigate", "open":
            return try await navigate(action.url)
        case "snapshot": return try await snapshot()
        case "click", "fill", "hover": return try await input(action)
        case "press": return try await press(action)
        case "scroll":
            return BrowserControlResult(
                success: true, content: try await script("scroll", arguments: ["dy": action.deltaY ?? 0]))
        case "wait", "wait_url", "wait_element", "wait_load":
            return try await waitFor(action)
        case "select": return try await select(action)
        case "screenshot":
            try await wait { tab.isVisible && tab.webView.bounds.width > 0 }
            return BrowserControlResult(success: true, png: try await capture())
        case "console":
            let text = try await evaluate(
                "return JSON.stringify(globalThis.__handshakeConsole || [])", arguments: [:], world: .page)
            return BrowserControlResult(success: true, content: text)
        default: throw BrowserAutomationError.unavailable("Unsupported browser operation.")
        }
    }

    private func press(_ action: BrowserAction) async throws -> BrowserControlResult {
        try await wait { tab.isVisible && tab.webView.window != nil && tab.webView.bounds.width > 0 }
        let generation = tab.navigationGeneration
        _ = try await script("prepareKey", arguments: ["key": action.key ?? ""])
        try Task.checkCancellation()
        guard generation == tab.navigationGeneration else {
            throw BrowserAutomationError.unavailable("The page changed before keyboard input.")
        }
        try BrowserNativeInput(tab: tab).press(action.key ?? "")
        return BrowserControlResult(success: true)
    }

    private func waitFor(_ action: BrowserAction) async throws -> BrowserControlResult {
        let deadline = Date().addingTimeInterval(25)
        while true {
            try Task.checkCancellation()
            let ready: Bool
            switch action.action {
            case "wait_url": ready = tab.address.contains(action.text ?? "")
            case "wait_load": ready = !tab.isLoading && tab.failure == nil
            case "wait_element":
                ready =
                    try await script(
                        "state", arguments: ["id": action.element ?? "", "state": action.state ?? "visible"]) == "true"
            default: ready = try await script("contains", arguments: ["text": action.text ?? ""]) == "true"
            }
            if ready { return try await snapshot() }
            guard Date() < deadline else {
                throw BrowserAutomationError.unavailable(
                    "The browser condition did not become true before the deadline.")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func select(_ action: BrowserAction) async throws -> BrowserControlResult {
        try await wait { tab.isVisible && tab.webView.window != nil && tab.webView.bounds.width > 0 }
        let arguments: [String: Any] = ["id": action.element ?? "", "value": action.value ?? ""]
        let generation = tab.navigationGeneration
        // Expire WebKit's previous typeahead prefix before one unambiguous native key.
        try await Task.sleep(for: .milliseconds(1100))
        let result = try await script("selection", arguments: arguments)
        let selection = try JSONDecoder().decode(BrowserSelection.self, from: Data(result.utf8))
        try Task.checkCancellation()
        guard generation == tab.navigationGeneration else {
            throw BrowserAutomationError.unavailable("The page changed during selection.")
        }
        if !selection.unchanged {
            try BrowserNativeInput(tab: tab).press(selection.key)
        }
        guard try await script("selected", arguments: arguments) == "true" else {
            throw BrowserAutomationError.unavailable("The dropdown did not select the requested value.")
        }
        return try await snapshot()
    }

    private func input(_ action: BrowserAction) async throws -> BrowserControlResult {
        try await wait { tab.isVisible && tab.webView.window != nil && tab.webView.bounds.width > 0 }
        let generation = tab.navigationGeneration
        let result = try await script(
            "target",
            arguments: [
                "id": action.element ?? "", "fill": action.action == "fill", "focus": action.action == "fill",
                "click": action.action == "click",
            ])
        let point = try JSONDecoder().decode(BrowserPoint.self, from: Data(result.utf8))
        try Task.checkCancellation()
        guard tab.isVisible, !tab.hasNativeSheet, !tab.isLoading, generation == tab.navigationGeneration else {
            throw BrowserAutomationError.unavailable("The page is not available for input.")
        }
        let input = BrowserNativeInput(tab: tab)
        switch action.action {
        case "click": try input.click(point)
        case "hover": try input.hover(point)
        default: try input.insert(action.text ?? "")
        }
        return BrowserControlResult(success: true, tab: tab.id.uuidString.lowercased())
    }

    private func navigate(_ value: String?) async throws -> BrowserControlResult {
        guard let value, let url = BrowserAddress.automationURL(value)
        else {
            throw BrowserAutomationError.unavailable("Use an HTTP(S) URL, local file URL, or absolute file path.")
        }
        if url.isFileURL {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue,
                FileManager.default.isReadableFile(atPath: url.path)
            else { throw BrowserAutomationError.unavailable("The local file is missing, unreadable, or a directory.") }
        }
        tab.load(url)
        try await wait { !tab.isLoading }
        if let failure = tab.failure { throw BrowserAutomationError.unavailable(failure) }
        return try await snapshot()
    }

    private func snapshot() async throws -> BrowserControlResult {
        BrowserControlResult(success: true, tab: tab.id.uuidString.lowercased(), content: try await script("snapshot"))
    }

    private func script(_ method: String, arguments: [String: Any] = [:]) async throws -> String {
        try await evaluate(
            "return JSON.stringify(globalThis.handshakeBrowser[method](args))",
            arguments: ["method": method, "args": arguments], world: .defaultClient)
    }

    private func evaluate(_ source: String, arguments: [String: Any], world: WKContentWorld) async throws -> String {
        try Task.checkCancellation()
        let pending = BrowserOperation()
        tab.webView.callAsyncJavaScript(source, arguments: arguments, in: nil, in: world) { result in
            switch result {
            case .success(let value): pending.result = .success(value as? String ?? "null")
            case .failure(let error): pending.result = .failure(error)
            }
        }
        return try await pending.value()
    }

    private func capture() async throws -> String {
        let pending = BrowserOperation()
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: min(tab.webView.bounds.width, 1600))
        tab.webView.takeSnapshot(with: configuration) { image, error in
            guard let data = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
                let png = bitmap.representation(using: .png, properties: [:]), png.count <= 8 * 1024 * 1024
            else {
                pending.result = .failure(
                    error ?? BrowserAutomationError.unavailable("Screenshot unavailable or too large."))
                return
            }
            pending.result = .success(png.base64EncodedString())
        }
        return try await pending.value()
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(25)
        while !condition() {
            try Task.checkCancellation()
            guard !tab.isClosed, Date() < deadline else {
                throw BrowserAutomationError.unavailable("The page did not become ready.")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
    }

}

/// Late WebKit callbacks cannot prolong a cancelled command or resume a continuation twice.
@MainActor
private final class BrowserOperation {
    var result: Result<String, any Error>?
    func value() async throws -> String {
        let deadline = Date().addingTimeInterval(5)
        while true {
            try Task.checkCancellation()
            if let result { return try result.get() }
            guard Date() < deadline else {
                throw BrowserAutomationError.unavailable("WebKit did not respond before the deadline.")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private struct BrowserSelection: Decodable {
    let key: String
    let unchanged: Bool
}
