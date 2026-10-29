import Foundation
import Testing
import WebKit

@testable import Handshake

@MainActor
struct BrowserLocalFileTests {
    @Test func localNavigationCannotEscapeItsGrantedDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "BrowserBoundary-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let allowed = directory.appending(path: "allowed")
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        let outside = directory.appending(path: "outside.html")
        try "Outside".write(to: outside, atomically: true, encoding: .utf8)
        let link = allowed.appending(path: "escape.html")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(BrowserTab.allowsLocalNavigation(to: allowed.appending(path: "page.html"), root: allowed))
        for url in [
            outside, link, allowed.appending(path: "../outside.html"),
            directory.appending(path: "allowed-other/page.html"),
        ] {
            #expect(!BrowserTab.allowsLocalNavigation(to: url, root: allowed))
        }
        // Website navigation clears the grant, including for previously opened files.
        #expect(!BrowserTab.allowsLocalNavigation(to: outside, root: nil))
    }

    @Test func localPagesLoadAssetsAndStayInTheBackground() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "BrowserLocal-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = directory.appending(path: "my page #1.html")
        try "<title>Local page</title><script src='asset.js'></script>".write(
            to: page, atomically: true, encoding: .utf8)
        try "document.title = 'Local assets loaded';".write(
            to: directory.appending(path: "asset.js"), atomically: true, encoding: .utf8)
        let selection = WorkspaceContentSelection()
        let selectedFile = UUID()
        selection.select(.file(selectedFile))
        let browsers = BrowserTabsModel(selection: selection)
        let tab = browsers.createControlled(id: UUID())
        defer { tab.close() }
        let driver = BrowserAutomationDriver(tab: tab)
        let result = try await driver.execute(.init(action: "open", url: page.path))
        #expect(result.content?.contains("Local assets loaded") == true)
        #expect(selection.content == .file(selectedFile))
        #expect(!tab.isVisible)
        _ = try await driver.execute(.init(action: "navigate", url: page.absoluteString))
        #expect(selection.content == .file(selectedFile))
        await #expect(throws: (any Error).self) {
            _ = try await driver.execute(.init(action: "navigate", url: directory.path))
        }
        await #expect(throws: (any Error).self) {
            _ = try await driver.execute(.init(action: "navigate", url: directory.appending(path: "missing.html").path))
        }
        let other = directory.appending(path: "other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let second = other.appending(path: "second.html")
        try "<title>Second directory</title>".write(to: second, atomically: true, encoding: .utf8)
        _ = try await driver.execute(.init(action: "navigate", url: second.path))
        tab.back()
        try await waitUntil { tab.pageTitle == "Local assets loaded" && !tab.isLoading }
        tab.forward()
        try await waitUntil { tab.pageTitle == "Second directory" && !tab.isLoading }
        let server = try BrowserFixtureServer(root: directory.appending(path: "site"))
        try await server.start()
        defer { server.stop() }
        _ = try await driver.execute(.init(action: "navigate", url: server.url("a").absoluteString))
        tab.back()
        try await waitUntil { tab.pageTitle == "Second directory" && !tab.isLoading }
    }

    @Test func automationAcceptsLocalPathsButRejectsRemoteFilesAndUnsafeSchemes() {
        #expect(BrowserAddress.automationURL("/tmp/my page #1.html")?.path == "/tmp/my page #1.html")
        #expect(BrowserAddress.automationURL("file:///tmp/my%20page.html")?.isFileURL == true)
        for address in [
            "file://remote.test/tmp/page.html", "file:relative.html", "javascript:alert(1)",
            "data:text/html,test", "https://user:pass@example.test",
        ] {
            #expect(BrowserAddress.automationURL(address) == nil)
        }
    }
}
