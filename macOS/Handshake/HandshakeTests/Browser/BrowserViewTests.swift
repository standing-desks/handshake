import AppKit
import SwiftUI
import Testing
import WebKit

@testable import Handshake

@MainActor
struct BrowserViewTests {
    @Test(arguments: [50, 100, 125, 200])
    func browserPageUsesOneZoomAndThePhysicalViewport(percent: Int) async throws {
        let suite = "BrowserViewTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(percent, forKey: "interfaceZoomPercent")
        let zoom = AppZoom(defaults: defaults)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = BrowserTab(configuration: configuration)
        defer { tab.close() }
        tab.load(try #require(URL(string: "about:blank")))
        let hosting = NSHostingView(
            rootView: BrowserView(tab: tab, isVisible: true, allowsAutomaticFocus: false)
                .appZoom().environment(\.appZoom, zoom))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.contentView = hosting
        for _ in 0..<200 {
            hosting.layoutSubtreeIfNeeded()
            if tab.webView.bounds.width > 0 && !tab.isLoading { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let page = tab.webView.convert(tab.webView.bounds, to: hosting)
        #expect(abs(page.width - 600) < 2)
        #expect(abs(page.maxY - 400) < 2)
        #expect(page.minY > 0)
        #expect(abs(tab.webView.bounds.width - 600) < 2)
        #expect(tab.webView.pageZoom == zoom.scale)
        let identity = ObjectIdentifier(tab.webView)
        window.setContentSize(CGSize(width: 800, height: 500))
        hosting.layoutSubtreeIfNeeded()
        #expect(ObjectIdentifier(tab.webView) == identity)
    }
}
