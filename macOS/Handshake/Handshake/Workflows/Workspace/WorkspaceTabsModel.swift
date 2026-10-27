import Foundation
import OSLog
import Observation

/// Folder-scoped presentation. Stable file paths and workflow IDs survive app relaunch.
@Observable
final class WorkspaceTabsModel {
    nonisolated struct Arrangement: Codable, Equatable {
        var order: [String] = []
        var pins: Set<String> = []
        var selection: String?
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
        saved.closed.filter { $0.file != nil || $0.browser != nil || $0.sessionID == session }
    }

    func didReopen(_ tab: ClosedTab, session: UInt64?) {
        saved.closed.removeAll { $0.id == tab.id }
        var value = arrangement(session)
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
