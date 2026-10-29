import Foundation
import OSLog
import Observation

/// Where a moved tab lands among a session's tabs.
nonisolated enum TabPlacement: Equatable {
    case end
    case before(String)
    case after(String)
}

/// Folder-scoped presentation. Stable file paths and workflow IDs survive app relaunch.
@Observable
final class WorkspaceTabsModel {
    nonisolated struct Arrangement: Codable, Equatable {
        var order: [String] = []
        var pins: Set<String> = []
        var selection: String?
        /// The file and browser tabs this session holds. Core owns which session holds a workflow.
        var pages: [String] = []

        init() {}

        init(from decoder: Decoder) throws {
            // Arrangements saved before sessions held pages decode with none.
            let values = try decoder.container(keyedBy: CodingKeys.self)
            order = try values.decodeIfPresent([String].self, forKey: .order) ?? []
            pins = try values.decodeIfPresent(Set<String>.self, forKey: .pins) ?? []
            selection = try values.decodeIfPresent(String.self, forKey: .selection)
            pages = try values.decodeIfPresent([String].self, forKey: .pages) ?? []
        }
    }

    nonisolated struct FileLocation: Codable, Equatable {
        let path: String
        let folder: String
        var memoryRequest: CoreMemoryRequest?
        var source: CoreMemorySource?
    }

    nonisolated struct ClosedTab: Codable, Identifiable {
        var id = UUID()
        let title: String
        let sessionID: UInt64?
        var workflowIDs: [UInt64] = []
        var file: FileLocation?
        var browser: BrowserTabsModel.Snapshot?
        var layout: WorkflowLayout?
        let reference: String
        let index: Int
        let pinned: Bool
    }

    nonisolated private struct Saved: Codable {
        var arrangements: [String: Arrangement] = [:]
        var files: [FileLocation] = []
        var closed: [ClosedTab] = []
    }

    private var saved: Saved
    private let defaults: UserDefaults
    private let key: String
    private(set) var filesRestored = false
    var showsSwitcher = false
    let dragScope = UUID().uuidString

    init(folder: String, defaults: UserDefaults = WorkflowLaunchPreferences.defaultStore()) {
        self.defaults = defaults
        key = "tabManagement:" + FolderWindows.canonicalPath(folder)
        saved = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
    }

    static func workflow(_ id: UInt64) -> String { "workflow:\(id)" }
    static func browser(_ id: UUID) -> String { "browser:\(id)" }
    static func file(_ path: String) -> String { "file:\(path)" }
    static func isPage(_ reference: String) -> Bool { reference.hasPrefix("file:") || reference.hasPrefix("browser:") }

    func arrangement(_ session: UInt64?) -> Arrangement { saved.arrangements[scope(session)] ?? Arrangement() }

    func ordered(_ references: [String], session: UInt64?) -> [String] {
        let arrangement = arrangement(session)
        let known = Set(references)
        let order = arrangement.order.filter { known.contains($0) }
        let combined = order + references.filter { !order.contains($0) }
        return combined.filter { arrangement.pins.contains($0) } + combined.filter { !arrangement.pins.contains($0) }
    }

    static func neighbor(in order: [String], closing: Set<String>, selected: String) -> String? {
        guard let index = order.firstIndex(of: selected) else { return nil }
        return order.dropFirst(index + 1).first { !closing.contains($0) }
            ?? order.prefix(index).reversed().first { !closing.contains($0) }
    }

    func reconcile(_ references: [String], session: UInt64?) {
        var value = arrangement(session)
        let order = ordered(references, session: session)
        let pins = value.pins.intersection(references)
        guard value.order != order || value.pins != pins else { return }
        value.pins = pins
        value.order = order
        update(value, session: session)
    }

    func promote(_ old: String, to replacement: String, previous: Arrangement, session: UInt64?) {
        var value = arrangement(session)
        let index = value.order.firstIndex(of: old) ?? previous.order.firstIndex(of: old) ?? value.order.count
        value.order.removeAll { $0 == old || $0 == replacement }
        value.order.insert(replacement, at: min(index, value.order.count))
        value.pins.remove(old)
        if previous.pins.contains(old) { value.pins.insert(replacement) }
        if value.selection == old { value.selection = replacement }
        update(value, session: session)
    }

    func select(_ reference: String?, session: UInt64?) {
        var value = arrangement(session)
        guard value.selection != reference else { return }
        value.selection = reference
        update(value, session: session)
    }

    func togglePin(_ reference: String, session: UInt64?) {
        var value = arrangement(session)
        if !value.pins.insert(reference).inserted { value.pins.remove(reference) }
        update(value, session: session)
    }

    func move(_ reference: String, before target: String, references: [String], session: UInt64?) {
        place(reference, relativeTo: target, after: false, references: references, session: session)
    }

    func place(_ reference: String, relativeTo target: String, after: Bool, references: [String], session: UInt64?) {
        guard reference != target else { return }
        var value = arrangement(session)
        // Pinned and unpinned tabs have distinct stable regions.
        guard value.pins.contains(reference) == value.pins.contains(target) else { return }
        var order = ordered(references, session: session)
        guard order.contains(reference), order.contains(target) else { return }
        order.removeAll { $0 == reference }
        guard let index = order.firstIndex(of: target) else { return }
        order.insert(reference, at: index + (after ? 1 : 0))
        value.order = order
        update(value, session: session)
    }

    func move(_ reference: String, by offset: Int, references: [String], session: UInt64?) {
        var value = arrangement(session)
        var order = ordered(references, session: session)
        guard let index = order.firstIndex(of: reference), order.indices.contains(index + offset),
            value.pins.contains(reference) == value.pins.contains(order[index + offset])
        else { return }
        order.swapAt(index, index + offset)
        value.order = order
        update(value, session: session)
    }

    func restoreFiles(into tabs: FileTabsModel) {
        guard !filesRestored else { return }
        filesRestored = true
        for file in saved.files {
            _ = tabs.restore(
                path: file.path, folder: file.folder, memoryRequest: file.memoryRequest, source: file.source)
        }
    }

    func rememberFiles(_ editors: [FileEditorModel]) {
        guard filesRestored else { return }
        let files = editors.map {
            FileLocation(path: $0.path, folder: $0.folder, memoryRequest: $0.memoryRequest, source: $0.memorySource)
        }
        guard files != saved.files else { return }
        saved.files = files
        persist()
    }

    func rememberClosed(_ tab: ClosedTab) {
        saved.closed.insert(tab, at: 0)
        saved.closed = Array(saved.closed.prefix(20))
        persist()
    }

    func recentlyClosed(session: UInt64?) -> [ClosedTab] {
        saved.closed.filter { $0.sessionID == session }
    }

    func didReopen(_ tab: ClosedTab, session: UInt64?) {
        saved.closed.removeAll { $0.id == tab.id }
        var value = arrangement(session)
        if Self.isPage(tab.reference), !value.pages.contains(tab.reference) { value.pages.append(tab.reference) }
        value.order.removeAll { $0 == tab.reference }
        value.order.insert(tab.reference, at: min(tab.index, value.order.count))
        if tab.pinned { value.pins.insert(tab.reference) }
        update(value, session: session)
    }

    private func scope(_ session: UInt64?) -> String { session.map(String.init) ?? "none" }

    private func update(_ value: Arrangement, session: UInt64?) {
        saved.arrangements[scope(session)] = value
        persist()
    }

    private func persist() {
        do { defaults.set(try JSONEncoder().encode(saved), forKey: key) } catch {
            Logger(subsystem: "com.twineproject.Twine", category: "tabs")
                .error("Could not encode tab preferences: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Pages held by sessions

extension WorkspaceTabsModel {
    /// Whether the session holds a file or browser tab.
    func holds(_ reference: String, session: UInt64?) -> Bool { arrangement(session).pages.contains(reference) }

    /// The other sessions that hold a file or browser tab.
    func otherHolders(of reference: String, besides session: UInt64?) -> [UInt64] {
        saved.arrangements.compactMap { key, value in
            guard key != scope(session), value.pages.contains(reference) else { return nil }
            return UInt64(key)
        }
        .sorted()
    }

    /// Opening a file or browser tab puts it in the selected session.
    func adopt(_ reference: String, session: UInt64?) {
        var value = arrangement(session)
        guard Self.isPage(reference), !value.pages.contains(reference) else { return }
        value.pages.append(reference)
        update(value, session: session)
    }

    /// Pages that no listed session holds join the listed session `owners` names for them, or else `session`.
    /// This places pages agents open, tabs opened before sessions held pages, and any left by a session that
    /// no longer exists.
    func adoptUnheld(
        _ references: [String], session: UInt64?, sessions: Set<UInt64>, owners: [String: UInt64] = [:]
    ) {
        let held = Set(
            saved.arrangements.filter { key, _ in UInt64(key).map(sessions.contains) == true }.values.flatMap(\.pages))
        for reference in references where Self.isPage(reference) && !held.contains(reference) {
            adopt(reference, session: owners[reference].flatMap { sessions.contains($0) ? $0 : nil } ?? session)
        }
    }

    /// Removes a tab from one session's arrangement. Returns whether another session still holds it.
    @discardableResult
    func release(_ reference: String, session: UInt64?) -> Bool {
        var value = arrangement(session)
        value.pages.removeAll { $0 == reference }
        value.order.removeAll { $0 == reference }
        value.pins.remove(reference)
        if value.selection == reference { value.selection = nil }
        update(value, session: session)
        return !otherHolders(of: reference, besides: session).isEmpty
    }

    /// Moves a tab between session arrangements. A moved tab arrives unpinned, because pins belong to each
    /// session. `references` are the destination's tabs. Returns false when the destination already held the
    /// page, so the two tabs merged.
    @discardableResult
    func transfer(
        _ reference: String, from source: UInt64?, to destination: UInt64?, at placement: TabPlacement,
        references: [String]
    ) -> Bool {
        guard source != destination else {
            let anchor: (target: String, after: Bool)? =
                switch placement {
                case .end: ordered(references, session: source).last { $0 != reference }.map { ($0, true) }
                case .before(let target): (target, false)
                case .after(let target): (target, true)
                }
            if let anchor {
                place(
                    reference, relativeTo: anchor.target, after: anchor.after, references: references, session: source)
            }
            return true
        }
        let merged = Self.isPage(reference) && holds(reference, session: destination)
        release(reference, session: source)
        guard !merged else { return false }
        var value = arrangement(destination)
        if Self.isPage(reference) { value.pages.append(reference) }
        var order = ordered(references.filter { $0 != reference }, session: destination)
        let unpinned = order.firstIndex { !value.pins.contains($0) } ?? order.count
        let index =
            switch placement {
            case .end: order.count
            case .before(let target): order.firstIndex(of: target) ?? order.count
            case .after(let target): order.firstIndex(of: target).map { $0 + 1 } ?? order.count
            }
        order.insert(reference, at: max(index, unpinned))
        value.order = order
        update(value, session: destination)
        return true
    }

    /// Removes a closed file or browser tab from every session.
    func releaseEverywhere(_ reference: String) {
        for (key, value) in saved.arrangements where value.pages.contains(reference) {
            var value = value
            value.pages.removeAll { $0 == reference }
            value.order.removeAll { $0 == reference }
            value.pins.remove(reference)
            if value.selection == reference { value.selection = nil }
            saved.arrangements[key] = value
        }
        persist()
    }

    /// Forgets file and browser tabs that are no longer open, such as those a closed folder left behind.
    func retainPages(_ open: Set<String>) {
        var changed = false
        for (key, value) in saved.arrangements where value.pages.contains(where: { !open.contains($0) }) {
            var value = value
            let gone = Set(value.pages.filter { !open.contains($0) })
            value.pages.removeAll { gone.contains($0) }
            value.order.removeAll { gone.contains($0) }
            value.pins.subtract(gone)
            if let selection = value.selection, gone.contains(selection) { value.selection = nil }
            saved.arrangements[key] = value
            changed = true
        }
        if changed { persist() }
    }

    /// Forgets the arrangements of sessions that no longer exist.
    func retainSessions(_ sessions: Set<UInt64>) {
        let stale = saved.arrangements.keys.filter { key in UInt64(key).map { !sessions.contains($0) } ?? false }
        guard !stale.isEmpty else { return }
        for key in stale { saved.arrangements.removeValue(forKey: key) }
        saved.closed.removeAll { $0.sessionID.map { !sessions.contains($0) } ?? false }
        persist()
    }
}
