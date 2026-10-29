import AppKit
import Observation
import WebKit

/// One retained WebKit page, including native history and navigation lifetime.
@Observable
final class BrowserTab: NSObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    let id: UUID
    let webView: WKWebView
    private(set) var navigationGeneration: UInt64 = 0
    var controlOwner: String?
    /// The session of the agent that opened this page, which holds it when it first appears.
    var agentSession: UInt64?
    /// The page that opened this one as a popup; the popup joins whichever session holds it.
    var opener: UUID?
    var stopControl: (() -> Void)?
    var controlDidClose: (() -> Void)?
    var customName: String? { didSet { changed?() } }
    private(set) var pageTitle = ""
    private(set) var url: URL?
    private(set) var isLoading = false
    private(set) var progress = 0.0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var failure: String?
    private(set) var isClosed = false
    private(set) var hasNavigated = false
    var isVisible = false { didSet { if !isVisible { dialogs.cancel() } } }
    var locationRequest = UUID()
    var changed: (() -> Void)?
    var popup: ((WKWebViewConfiguration) -> WKWebView?)?
    var closeRequested: (() -> Void)?
    var openExternal: (URL) -> Void = { NSWorkspace.shared.open($0) }
    private let dialogs = BrowserDialogs()
    private var observations: [NSKeyValueObservation] = []
    private var navigation: WKNavigation?
    private var pendingURL: URL?
    private var failedURL: URL?
    private var stoppedURL: URL?
    private var stoppedNavigation: WKNavigation?
    private var isStopped = false

    init(
        id: UUID = UUID(), configuration: WKWebViewConfiguration = WKWebViewConfiguration(), customName: String? = nil,
        hasNavigated: Bool = false, automation: Bool = false
    ) {
        self.id = id
        self.customName = customName
        self.hasNavigated = hasNavigated
        if automation { BrowserAutomationDriver.configure(configuration) }
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        dialogs.presentationChanged = { [weak self] visible in self?.webView.setAccessibilityHidden(visible) }
        webView.allowsBackForwardNavigationGestures = true
        webView.setAccessibilityIdentifier("browserPage-\(id)")
        observations = [
            webView.observe(\.title) { [weak self] _, _ in self?.scheduleSync() },
            webView.observe(\.url) { [weak self] _, _ in self?.scheduleSync() },
            webView.observe(\.isLoading) { [weak self] _, _ in self?.scheduleSync() },
            webView.observe(\.estimatedProgress) { [weak self] _, _ in self?.scheduleSync() },
            webView.observe(\.canGoBack) { [weak self] _, _ in self?.scheduleSync() },
            webView.observe(\.canGoForward) { [weak self] _, _ in self?.scheduleSync() },
        ]
    }

    var hasNativeSheet: Bool { dialogs.isPresenting }
    var defaultTitle: String { pageTitle.isEmpty ? (url?.host ?? "New Browser Tab") : pageTitle }
    var title: String { customName ?? defaultTitle }
    var address: String { (url ?? pendingURL)?.absoluteString ?? "" }
    var snapshot: BrowserTabsModel.Snapshot {
        .init(id: id, url: (failedURL ?? url ?? pendingURL)?.absoluteString, customName: customName)
    }

    nonisolated private func scheduleSync() {
        Task { @MainActor [weak self] in self?.syncState() }
    }

    private func syncState() {
        guard !isClosed else { return }
        pageTitle = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        url = webView.url
        isLoading = !isStopped && webView.isLoading
        progress = webView.estimatedProgress
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        changed?()
    }

    func load(_ url: URL) {
        guard !isClosed else { return }
        navigationGeneration &+= 1
        isStopped = false
        stoppedURL = nil
        hasNavigated = true
        failure = nil
        failedURL = nil
        pendingURL = url
        navigation = webView.load(URLRequest(url: url))
        syncState()
    }

    func back() {
        guard !isClosed, webView.canGoBack else { return }
        failure = nil
        isStopped = false
        stoppedURL = nil
        pendingURL = webView.backForwardList.backItem?.url
        navigation = webView.goBack()
    }
    func forward() {
        guard !isClosed, webView.canGoForward else { return }
        failure = nil
        isStopped = false
        stoppedURL = nil
        pendingURL = webView.backForwardList.forwardItem?.url
        navigation = webView.goForward()
    }
    func reload() {
        guard !isClosed else { return }
        if let retry = failedURL ?? stoppedURL ?? (webView.url == nil ? pendingURL : nil) {
            load(retry)
        } else {
            failure = nil
            navigation = webView.reload()
        }
    }
    func stop() {
        guard !isClosed else { return }
        isStopped = true
        stoppedURL = pendingURL ?? webView.url
        stoppedNavigation = navigation
        navigation = nil
        webView.stopLoading()
        failure = nil
        failedURL = nil
        syncState()
    }

    func close() {
        guard !isClosed else { return }
        controlDidClose?()
        controlDidClose = nil
        stopControl = nil
        controlOwner = nil
        isClosed = true
        isVisible = false
        navigation = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        for observation in observations { observation.invalidate() }
        observations.removeAll()
        popup = nil
        changed = nil
        closeRequested = nil
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard !isClosed, let destination = action.request.url else {
            decisionHandler(.cancel)
            return
        }
        let scheme = destination.scheme?.lowercased() ?? ""
        if ["http", "https", "about", "blob", "data"].contains(scheme) {
            if action.targetFrame?.isMainFrame == true {
                pendingURL = destination
                hasNavigated = true
            }
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            let external = Self.opensExternally(
                scheme: scheme, userClicked: action.navigationType == .linkActivated, visible: isVisible)
            if external {
                openExternal(destination)
            }
        }
    }

    nonisolated static func opensExternally(scheme: String, userClicked: Bool, visible: Bool) -> Bool {
        userClicked && visible
            && !["", "http", "https", "file", "javascript", "about", "blob", "data", "webkit", "applewebdata"].contains(
                scheme)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        guard !isClosed else { return }
        navigationGeneration &+= 1
        if let navigation, navigation === stoppedNavigation {
            if self.navigation == nil { webView.stopLoading() }
            return
        }
        isStopped = false
        stoppedURL = nil
        stoppedNavigation = nil
        self.navigation = navigation
        failure = nil
        failedURL = nil
        hasNavigated = true
        syncState()
    }
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation?) {
        guard !isClosed, navigation === self.navigation else { return }
        pendingURL = webView.url ?? pendingURL
        syncState()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        guard !isClosed, navigation === self.navigation else { return }
        failure = nil
        failedURL = nil
        pendingURL = webView.url
        syncState()
    }
    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: any Error
    ) {
        navigationFailed(navigation, error: error)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
        navigationFailed(navigation, error: error)
    }
    private func navigationFailed(_ navigation: WKNavigation?, error: any Error) {
        guard !isClosed, let navigation, navigation === self.navigation else { return }
        let error = error as NSError
        guard !(error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled) else { return }
        failedURL = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? pendingURL ?? webView.url
        failure = error.localizedDescription
        syncState()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !isClosed else { return }
        failure = "This page stopped responding. Reload to try again."
        failedURL = webView.url ?? pendingURL
        syncState()
    }

}

extension BrowserTab {
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard !isClosed, isVisible, action.targetFrame == nil else { return nil }
        return popup?(configuration)
    }
    func webViewDidClose(_ webView: WKWebView) { if !isClosed { closeRequested?() } }

    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor () -> Void
    ) {
        dialogs.alert(
            message, origin: frame.securityOrigin.host, window: isVisible ? webView.window : nil,
            completion: completionHandler)
    }
    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (Bool) -> Void
    ) {
        dialogs.confirm(
            message, origin: frame.securityOrigin.host, window: isVisible ? webView.window : nil,
            completion: completionHandler)
    }
    func webView(
        _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void
    ) {
        dialogs.prompt(
            prompt, value: defaultText, origin: frame.securityOrigin.host, window: isVisible ? webView.window : nil,
            completion: completionHandler)
    }
    func webView(
        _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor ([URL]?) -> Void
    ) {
        dialogs.files(parameters, window: isVisible ? webView.window : nil, completion: completionHandler)
    }
}
