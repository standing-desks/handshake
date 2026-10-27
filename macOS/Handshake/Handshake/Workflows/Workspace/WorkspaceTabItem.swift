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
        let counts = Dictionary(grouping: workflows, by: { $0.customName ?? $0.name }).mapValues(\.count)
        return Dictionary(
            uniqueKeysWithValues: workflows.map { workflow in
                let title = workflow.customName ?? workflow.name
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
