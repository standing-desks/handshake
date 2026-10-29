import Foundation
import Observation
import WebKit

/// A folder window owns the actual pages. Session changes only affect workflow presentation.
@Observable
final class BrowserTabsModel {
    nonisolated struct Snapshot: Codable, Equatable, Identifiable, Sendable {
        var id: UUID
        var url: String?
        var customName: String?
    }

    private(set) var tabs: [BrowserTab] = []
    let selection: WorkspaceContentSelection
    let windowID: UUID?
    var visualOrder: [UUID]?
    var willClose: ((BrowserTab) -> Void)?
    private let defaults: UserDefaults
    private let configuration: @MainActor () -> WKWebViewConfiguration
    private var folder: String?
    private var lastSaved: [Snapshot] = []
    private(set) var isClosing = false

    init(
        selection: WorkspaceContentSelection, windowID: UUID? = nil,
        defaults: UserDefaults = WorkflowLaunchPreferences.defaultStore(),
        configuration: @escaping @MainActor () -> WKWebViewConfiguration = BrowserConfiguration.make
    ) {
        self.selection = selection
        self.windowID = windowID
        self.defaults = defaults
        self.configuration = configuration
    }

    var selectedID: UUID? {
        if case .browser(let id) = selection.content { return id }
        return nil
    }
    var selected: BrowserTab? { tabs.first { $0.id == selectedID } }

    func configure(folder: String) {
        let canonical = FolderWindows.canonicalPath(folder)
        let changedFolder = self.folder != canonical
        if changedFolder {
            closeAll(preservingPresentation: true)
            self.folder = canonical
            isClosing = false
            lastSaved = []
        }
        let shouldRestore = changedFolder && tabs.isEmpty
        let restored = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Snapshot].self, from: $0) }
        if shouldRestore, let snapshots = restored {
            lastSaved = snapshots
            for snapshot in snapshots where !tabs.contains(where: { $0.id == snapshot.id }) {
                _ = insert(snapshot: snapshot, configuration: configuration(), select: false)
            }
        }
        isClosing = false
        remember()
    }

    @discardableResult
    func create() -> BrowserTab {
        insert(snapshot: .init(id: UUID()), configuration: configuration(), select: true)
    }

    func createControlled(id: UUID) -> BrowserTab {
        insert(snapshot: .init(id: id), configuration: configuration(), select: false, automation: true)
    }

    @discardableResult
    func restore(_ snapshot: Snapshot) -> BrowserTab {
        if let existing = tabs.first(where: { $0.id == snapshot.id }) {
            select(existing.id)
            return existing
        }
        return insert(snapshot: snapshot, configuration: configuration(), select: true)
    }

    private func insert(
        snapshot: Snapshot, configuration: WKWebViewConfiguration, select: Bool, hasNavigated: Bool = false,
        automation: Bool = false
    ) -> BrowserTab {
        let tab = BrowserTab(
            id: snapshot.id, configuration: configuration, customName: snapshot.customName, hasNavigated: hasNavigated,
            automation: automation)
        tab.changed = { [weak self] in self?.remember() }
        tab.popup = { [weak self, weak tab] configuration in
            guard let self, let tab, !isClosing, tabs.contains(where: { $0 === tab }) else { return nil }
            let popup = insert(
                snapshot: .init(id: UUID()), configuration: configuration, select: true, hasNavigated: true)
            popup.opener = tab.id
            return popup.webView
        }
        tab.closeRequested = { [weak self, weak tab] in if let tab { self?.close(tab.id) } }
        tabs.append(tab)
        if let value = snapshot.url, let url = BrowserAddress.parse(value) ?? BrowserAddress.automationURL(value) {
            tab.load(url)
        }
        if select { self.select(tab.id) }
        remember()
        return tab
    }

    func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }), !isClosing else { return }
        selection.select(.browser(id))
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]
        willClose?(tab)
        // The next tab comes from the shown order, which holds only the selected session's pages. Without a tab
        // bar to set it, any open page can be next.
        let known = tabs.map(\.id)
        let order = visualOrder.map { $0.filter(known.contains) } ?? known
        let next = order.firstIndex(of: id).flatMap { index in
            order.dropFirst(index + 1).first ?? order.prefix(index).last
        }
        tabs.remove(at: index)
        tab.close()
        if selectedID == id { selection.select(next.map(WorkspaceContentSelection.Content.browser)) }
        remember()
    }

    func closeAll(preservingPresentation: Bool = false) {
        if preservingPresentation { remember() }
        isClosing = true
        for tab in tabs { tab.close() }
        tabs.removeAll()
        if selectedID != nil { selection.select(nil) }
        willClose = nil
        visualOrder = nil
        if !preservingPresentation {
            lastSaved = []
            defaults.removeObject(forKey: key)
        }
    }

    func remember() {
        guard folder != nil, !isClosing else { return }
        let snapshots = tabs.map(\.snapshot)
        guard snapshots != lastSaved, let data = try? JSONEncoder().encode(snapshots) else { return }
        lastSaved = snapshots
        defaults.set(data, forKey: key)
    }

    private var key: String { "browserTabs:" + (folder ?? "") }
}
