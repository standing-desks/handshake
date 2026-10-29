import SwiftUI

/// Display metadata shared by the tab strip and searchable switcher.
struct WorkspaceTabItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    var workflow: CoreWorkflow?
    var fileID: UUID?
    var isDirty = false
    var browser: BrowserTab?
    var pinned = false
    /// The tab's session, when a list mixes sessions and one file can appear in several.
    var scope: UInt64?

    /// Unique in the tab switcher, even when the same file is open in two sessions.
    var switcherKey: String { scope.map { "\($0)|\(id)" } ?? id }

    var accessibilityID: String {
        if let workflow { return "workflowTab-\(workflow.id)" }
        if let browser { return "browserTab-\(browser.id)" }
        return "fileTab-\(String(id.dropFirst(5)))"
    }

    var closeID: String {
        if let workflow { return "closeWorkflow-\(workflow.id)" }
        if let browser { return "closeBrowser-\(browser.id)" }
        return "closeFile-\(String(id.dropFirst(5)))"
    }
    var canRename: Bool { workflow != nil || browser != nil }
    var renameValue: String { customName ?? workflow?.name ?? browser?.defaultTitle ?? title }
    var customName: String? { workflow?.customName ?? browser?.customName }
    var status: String? { workflow?.status == .completed ? "Done" : nil }

    /// What a sidebar row shows about its workflow, most urgent first.
    enum Activity: Int, Comparable {
        case done, running, needsAttention

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        var description: String {
            switch self {
            case .done: "Done"
            case .running: "Running"
            case .needsAttention: "Needs attention"
            }
        }
    }

    var activity: Activity? {
        guard let workflow else { return nil }
        switch (workflow.status, workflow.run?.status) {
        case (.failed, _), (.interrupted, _), (_, .limitReached), (_, .failed): return .needsAttention
        case (.running, _) where workflow.isRunningAgent: return .running
        case (.completed, _): return .done
        default: return nil
        }
    }
    var statusSymbol: String? { status == nil ? nil : "checkmark.circle" }
    var statusColor: Color { .green }

    static func browserTitles(_ tabs: [BrowserTab]) -> [UUID: String] {
        let groups = Dictionary(grouping: tabs, by: \.title)
        return Dictionary(
            uniqueKeysWithValues: tabs.map { tab in
                let peers = groups[tab.title, default: []]
                guard peers.count > 1 else { return (tab.id, tab.title) }
                let address = tab.url?.host ?? ""
                if !address.isEmpty, peers.filter({ $0.url?.host == tab.url?.host }).count == 1 {
                    return (tab.id, "\(tab.title) · \(address)")
                }
                return (tab.id, "\(tab.title) · \(tab.id.uuidString.prefix(4))")
            })
    }

    static func workflowTitles(_ workflows: [CoreWorkflow]) -> [UInt64: String] {
        let counts = Dictionary(grouping: workflows, by: { $0.customName ?? $0.automaticTitle }).mapValues(\.count)
        return Dictionary(
            uniqueKeysWithValues: workflows.map { workflow in
                let title = workflow.customName ?? workflow.automaticTitle
                return (workflow.id, counts[title, default: 0] > 1 ? "\(title) · \(workflow.id)" : title)
            })
    }

    static func fileTitles(_ editors: [FileEditorModel]) -> [UUID: String] {
        let groups = Dictionary(grouping: editors, by: \.displayName)
        return Dictionary(
            uniqueKeysWithValues: editors.map { editor in
                let peers = groups[editor.displayName, default: []]
                guard peers.count > 1 else { return (editor.id, editor.displayName) }
                let components = URL(filePath: editor.path).pathComponents
                for length in 2...max(2, components.count) {
                    let suffix = components.suffix(length).joined(separator: "/")
                    if peers.filter({
                        URL(filePath: $0.path).pathComponents.suffix(length).joined(separator: "/") == suffix
                    }).count == 1 {
                        return (editor.id, suffix)
                    }
                }
                return (editor.id, editor.path)
            })
    }
}

extension WorkspaceTabItem {
    /// One session's tabs in display order: its workflows, and the file and browser tabs it holds.
    /// `workflows` are the session's tab workflows, one per split.
    static func items(
        session: UInt64?, workflows: [CoreWorkflow], files: FileTabsModel, browsers: BrowserTabsModel,
        model: WorkspaceTabsModel
    ) -> [WorkspaceTabItem] {
        let arrangement = model.arrangement(session)
        let pages = Set(arrangement.pages)
        let editors = files.editors.filter { pages.contains(WorkspaceTabsModel.file($0.path)) }
        let pageTabs = browsers.tabs.filter { pages.contains(WorkspaceTabsModel.browser($0.id)) }
        let workflowTitles = workflowTitles(workflows)
        let fileTitles = fileTitles(editors)
        let browserTitles = browserTitles(pageTabs)
        var items = workflows.map { workflow in
            let id = WorkspaceTabsModel.workflow(workflow.id)
            let harnesses = workflow.run?.agents.map { $0.harness.displayName } ?? []
            let detail =
                ([workflow.name, workflow.harness?.displayName].compactMap { $0 } + Array(Set(harnesses)).sorted())
                .joined(separator: " · ")
            return WorkspaceTabItem(
                id: id, title: workflowTitles[workflow.id] ?? workflow.name,
                detail: detail, symbol: workflow.tabSymbol, workflow: workflow,
                pinned: arrangement.pins.contains(id))
        }
        items += editors.map { editor in
            let id = WorkspaceTabsModel.file(editor.path)
            return WorkspaceTabItem(
                id: id, title: fileTitles[editor.id] ?? editor.displayName, detail: editor.path,
                symbol: "doc.text", fileID: editor.id, isDirty: editor.isDirty, pinned: arrangement.pins.contains(id))
        }
        items += pageTabs.map { tab in
            let id = WorkspaceTabsModel.browser(tab.id)
            return WorkspaceTabItem(
                id: id, title: browserTitles[tab.id] ?? tab.title, detail: tab.address, symbol: "globe",
                browser: tab, pinned: arrangement.pins.contains(id))
        }
        let lookup = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return model.ordered(items.map(\.id), session: session).compactMap { lookup[$0] }
    }
}
