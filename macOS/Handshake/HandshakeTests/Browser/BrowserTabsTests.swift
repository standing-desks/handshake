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

    @Test func snapshotsRestoreForTheirFolder() throws {
        let defaults = try #require(UserDefaults(suiteName: "BrowserTabsTests-\(UUID())"))
        let selection = WorkspaceContentSelection()
        let model = BrowserTabsModel(selection: selection, defaults: defaults, configuration: isolated)
        model.configure(folder: "/tmp/browser")
        let tab = model.create()
        tab.customName = "Reference"
        let id = tab.id
        model.closeAll(preservingPresentation: true)
        let fresh = BrowserTabsModel(selection: selection, defaults: defaults, configuration: isolated)
        fresh.configure(folder: "/tmp/browser")
        #expect(fresh.tabs.map(\.id) == [id])
        #expect(fresh.tabs.first?.customName == "Reference")
        #expect(fresh.tabs.first?.webView.configuration.websiteDataStore.isPersistent == false)
        fresh.closeAll()
        fresh.configure(folder: "/tmp/other")
        #expect(fresh.tabs.isEmpty)
        fresh.closeAll()
    }

    @Test func closedBrowserTabsReopenInTheirSessionWithNamePositionAndPin() throws {
        let defaults = try #require(UserDefaults(suiteName: "BrowserHistoryTests-\(UUID())"))
        let model = WorkspaceTabsModel(folder: "/tmp/browser", defaults: defaults)
        let snapshot = BrowserTabsModel.Snapshot(id: UUID(), url: "about:blank", customName: "Notes")
        let reference = WorkspaceTabsModel.browser(snapshot.id)
        let closed = WorkspaceTabsModel.ClosedTab(
            title: "Notes", sessionID: 10, browser: snapshot, reference: reference, index: 0, pinned: true)
        model.rememberClosed(closed)
        let restored = WorkspaceTabsModel(folder: "/tmp/browser", defaults: defaults)
        #expect(restored.recentlyClosed(session: 10).first?.browser == snapshot)
        #expect(restored.recentlyClosed(session: 20).isEmpty, "Browser tabs belong to the session they closed from")
        restored.didReopen(closed, session: 10)
        #expect(restored.holds(reference, session: 10))
        #expect(restored.arrangement(10).pins.contains(reference))
        #expect(restored.ordered(["workflow:1", reference], session: 10) == [reference, "workflow:1"])
    }

    @Test func duplicateBrowserNamesRemainDistinctAndPopupContentIsNotAFreshTab() throws {
        let model = BrowserTabsModel(selection: WorkspaceContentSelection(), configuration: isolated)
        defer { model.closeAll() }
        let first = model.create()
        let second = model.create()
        first.customName = "Reference"
        second.customName = "Reference"
        let titles = WorkspaceTabItem.browserTitles(model.tabs)
        #expect(titles[first.id] != titles[second.id])
        #expect(first.hasNavigated == false)
        let configuration = isolated()
        let view = try #require(first.popup?(configuration))
        #expect(model.selected?.webView === view)
        #expect(model.selected?.hasNavigated == true)
    }

    @Test func sessionNavigationClearsPageSelectionAndInvalidatesFileRequests() {
        let selection = WorkspaceContentSelection()
        selection.select(.browser(UUID()))
        let generation = selection.generation
        selection.showSession()
        #expect(selection.content == nil, "Each session restores its own selection, including its browser tabs")
        #expect(selection.generation != generation)
        selection.select(.file(UUID()))
        selection.showSession()
        #expect(selection.content == nil)
    }

    @Test func closingASessionsLastPageDoesNotShowAnotherSessionsPage() {
        let files = FileTabsModel()
        let browsers = BrowserTabsModel(selection: files.contentSelection, configuration: isolated)
        defer { browsers.closeAll() }
        let mine = browsers.create()
        _ = browsers.create()
        // The shown order holds only the selected session's pages.
        browsers.visualOrder = [mine.id]
        browsers.select(mine.id)
        browsers.close(mine.id)
        #expect(browsers.selected == nil)
        #expect(files.contentSelection.content == nil)
        // A session without pages of its own can show an agent's page; closing it shows no other page.
        let agent = browsers.create()
        browsers.visualOrder = []
        browsers.close(agent.id)
        #expect(browsers.selected == nil)
    }

    private func isolated() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return configuration
    }
}
