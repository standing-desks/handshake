import Foundation
import Testing
import WebKit

@testable import Handshake

@MainActor
struct BrowserTabsTests {
    @Test func sharedSelectionCloseOrderAndUnknownIDs() throws {
        let files = FileTabsModel()
        let browsers = BrowserTabsModel(selection: files.contentSelection, configuration: isolated)
        let first = browsers.create()
        let second = browsers.create()
        let third = browsers.create()
        defer { browsers.closeAll() }
        browsers.select(first.id)
        browsers.select(UUID())
        #expect(browsers.selected === first)
        let editor = files.open(path: "/tmp/note", folder: "/tmp")
        #expect(browsers.selected == nil)
        browsers.close(second.id)
        #expect(files.selected === editor)
        browsers.select(first.id)
        #expect(files.selected == nil)
        browsers.visualOrder = [third.id, first.id]
        browsers.close(first.id)
        #expect(browsers.selected === third)
        browsers.close(third.id)
        #expect(files.contentSelection.content == nil)
        #expect(files.editors.count == 1)
    }

    @Test func snapshotsRestoreOnlyWhenTabManagementIsEnabled() throws {
        let defaults = try #require(UserDefaults(suiteName: "BrowserTabsTests-\(UUID())"))
        let selection = WorkspaceContentSelection()
        let model = BrowserTabsModel(selection: selection, defaults: defaults, configuration: isolated)
        model.configure(folder: "/tmp/browser", persistenceEnabled: true)
        let tab = model.create()
        tab.customName = "Reference"
        let id = tab.id
        model.closeAll(preservingPresentation: true)
        let fresh = BrowserTabsModel(selection: selection, defaults: defaults, configuration: isolated)
        fresh.configure(folder: "/tmp/browser", persistenceEnabled: false)
        #expect(fresh.tabs.isEmpty)
        fresh.configure(folder: "/tmp/browser", persistenceEnabled: true)
        #expect(fresh.tabs.map(\.id) == [id])
        #expect(fresh.tabs.first?.customName == "Reference")
        #expect(fresh.tabs.first?.webView.configuration.websiteDataStore.isPersistent == false)
        fresh.closeAll()
        fresh.configure(folder: "/tmp/other", persistenceEnabled: true)
        #expect(fresh.tabs.isEmpty)
        fresh.closeAll()
    }

    @Test func browserHistoryRestoresNamePositionAndPinAcrossSessions() throws {
        let defaults = try #require(UserDefaults(suiteName: "BrowserHistoryTests-\(UUID())"))
        let model = WorkspaceTabsModel(folder: "/tmp/browser", defaults: defaults)
        let snapshot = BrowserTabsModel.Snapshot(id: UUID(), url: "about:blank", customName: "Notes")
        let reference = WorkspaceTabsModel.browser(snapshot.id)
        let closed = WorkspaceTabsModel.ClosedTab(
            title: "Notes", sessionID: 10, browser: snapshot, reference: reference, index: 0, pinned: true)
        model.rememberClosed(closed)
        let restored = WorkspaceTabsModel(folder: "/tmp/browser", defaults: defaults)
        #expect(restored.recentlyClosed(session: 20).first?.browser == snapshot)
        restored.didReopen(closed, session: 20)
        #expect(restored.arrangement(20).pins.contains(reference))
        #expect(restored.ordered(["workflow:1", reference], session: 20) == [reference, "workflow:1"])
    }

    private func isolated() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return configuration
    }
}
