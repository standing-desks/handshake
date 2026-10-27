import AppKit
import Foundation
import Testing
import WebKit

@testable import Handshake

@MainActor
struct BrowserWebKitTests {
    @Test func navigationRetainsDOMHistoryAndWebViewAcrossSelectionChanges() async throws {
        let temporary = TemporaryPath()
        let server = try BrowserFixtureServer(root: temporary.url)
        try await server.start()
        defer { server.stop() }
        let selection = WorkspaceContentSelection()
        let model = BrowserTabsModel(selection: selection, configuration: isolated)
        let first = model.create()
        defer { model.closeAll() }
        first.load(try server.url("a"))
        try await waitUntil { first.pageTitle == "Page A" && !first.isLoading }
        let identity = ObjectIdentifier(first.webView)
        _ = try await first.webView.evaluateJavaScript(
            "note.value='retained note'; window.retained=42; scrollTo(0,900)")
        let second = model.create()
        second.load(try server.url("b"))
        try await waitUntil { second.pageTitle == "Page B" && !second.isLoading }
        selection.select(.file(UUID()))
        model.select(first.id)
        #expect(ObjectIdentifier(first.webView) == identity)
        #expect(try await first.webView.evaluateJavaScript("note.value") as? String == "retained note")
        #expect(try await first.webView.evaluateJavaScript("window.retained") as? Int == 42)
        _ = try await first.webView.evaluateJavaScript("location.href='/b'")
        try await waitUntil { first.pageTitle == "Page B" && first.canGoBack && !first.isLoading }
        first.back()
        try await waitUntil { first.pageTitle == "Page A" && first.canGoForward && !first.isLoading }
        first.forward()
        try await waitUntil { first.pageTitle == "Page B" && !first.isLoading }
        #expect(second.webView.backForwardList.backList.isEmpty)
    }

    @Test func redirectsFailuresRetryTheFailedLinkAndStopDoesNotShowAnError() async throws {
        let temporary = TemporaryPath()
        let server = try BrowserFixtureServer(root: temporary.url)
        try await server.start()
        defer { server.stop() }
        let tab = BrowserTab(configuration: isolated())
        defer { tab.close() }
        tab.load(try server.url("redirect"))
        try await waitUntil { tab.url?.path == "/b" && !tab.isLoading }
        _ = try await tab.webView.evaluateJavaScript("location.href='/drop'")
        try await waitUntil { tab.failure != nil }
        try Data().write(to: temporary.url.appending(path: "allow-drop"))
        tab.reload()
        try await waitUntil { tab.url?.path == "/drop" && tab.failure == nil && !tab.isLoading }
        tab.load(try server.url("slow"))
        try await waitUntil { tab.isLoading }
        tab.stop()
        try await Task.sleep(for: .milliseconds(200))
        #expect(tab.failure == nil)
        #expect(!tab.isLoading)
        // A new scripted navigation to the same stopped destination must remain possible.
        _ = try await tab.webView.evaluateJavaScript("location.href='/slow'")
        try await waitUntil { tab.pageTitle == "Slow page" && !tab.isLoading }
        tab.back()
        tab.stop()
        try await assertRemainsStopped(tab)
        tab.webViewWebContentProcessDidTerminate(tab.webView)
        #expect(tab.failure == "This page stopped responding. Reload to try again.")
        tab.close()
        tab.webViewWebContentProcessDidTerminate(tab.webView)
        #expect(tab.isClosed)
        #expect(tab.webView.navigationDelegate == nil)
        #expect(tab.webView.uiDelegate == nil)
    }

    @Test func popupUsesSuppliedConfigurationAndLoadsOnlyOnce() async throws {
        let temporary = TemporaryPath()
        let server = try BrowserFixtureServer(root: temporary.url)
        try await server.start()
        defer { server.stop() }
        let store = WKWebsiteDataStore.nonPersistent()
        let model = BrowserTabsModel(
            selection: WorkspaceContentSelection(),
            configuration: {
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = store
                configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
                return configuration
            })
        defer { model.closeAll() }
        let first = model.create()
        first.isVisible = true
        first.load(try server.url("a"))
        try await waitUntil { first.pageTitle == "Page A" && !first.isLoading }
        _ = try await first.webView.evaluateJavaScript("window.child=window.open('/popup'); true")
        try await waitUntil { model.tabs.count == 2 && model.selected?.pageTitle == "Page POPUP" }
        let child = try #require(model.selected)
        #expect(child.webView.configuration.websiteDataStore === store)
        let requests = try String(contentsOf: temporary.url.appending(path: "requests"), encoding: .utf8)
        #expect(requests.components(separatedBy: "\n").filter { $0 == "/popup" }.count == 1)
        _ = try await child.webView.evaluateJavaScript("window.close(); true")
        try await waitUntil { model.tabs.count == 1 }
        #expect(model.selected === first)
    }

    @Test func sharedWebsiteDataHiddenDialogsAndBlockedLocalNavigation() async throws {
        let temporary = TemporaryPath()
        let server = try BrowserFixtureServer(root: temporary.url)
        try await server.start()
        defer { server.stop() }
        let store = WKWebsiteDataStore.nonPersistent()
        let model = BrowserTabsModel(
            selection: WorkspaceContentSelection(),
            configuration: {
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = store
                return configuration
            })
        defer { model.closeAll() }
        let first = model.create()
        first.load(try server.url("cookie"))
        try await waitUntil { first.pageTitle == "Page A" && !first.isLoading }
        let second = model.create()
        second.load(try server.url("b"))
        try await waitUntil { second.pageTitle == "Page B" && !second.isLoading }
        #expect(
            try await second.webView.evaluateJavaScript("document.cookie.includes('fixture=shared')") as? Bool == true)
        #expect(try await first.webView.evaluateJavaScript("confirm('hidden')") as? Bool == false)
        #expect(try await first.webView.evaluateJavaScript("prompt('hidden') === null") as? Bool == true)
        _ = try await first.webView.evaluateJavaScript("alert('hidden'); true")
        _ = try await first.webView.evaluateJavaScript("location.href='file:///etc/hosts'")
        try await Task.sleep(for: .milliseconds(150))
        #expect(first.webView.url?.scheme == "http")
        #expect(first.failure == nil)
    }

    @Test func productionPagesUseThePersistentStoreAndDefaultPopupPolicy() {
        let tab = BrowserTab()
        defer { tab.close() }
        #expect(tab.webView.configuration.websiteDataStore.isPersistent)
        #expect(
            tab.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically
                == WKWebViewConfiguration().preferences.javaScriptCanOpenWindowsAutomatically)
    }

    @Test func publicInternetSmokeIsOptIn() async throws {
        guard ProcessInfo.processInfo.environment["HANDSHAKE_BROWSER_INTERNET_TEST"] == "1" else { return }
        let tab = BrowserTab(configuration: isolated())
        defer { tab.close() }
        tab.load(try #require(URL(string: "https://example.com")))
        try await waitUntil { tab.pageTitle == "Example Domain" && !tab.isLoading }
        #expect(tab.failure == nil)
    }

    private func assertRemainsStopped(_ tab: BrowserTab) async throws {
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(25))
            #expect(!tab.isLoading)
            #expect(tab.failure == nil)
        }
    }

    private func isolated() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return configuration
    }

    private func waitUntil(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<400 {
            if (try? await condition()) == true { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Timed out waiting for WebKit fixture")
        throw FixtureTimeout.expired
    }
    private enum FixtureTimeout: Error { case expired }
}
