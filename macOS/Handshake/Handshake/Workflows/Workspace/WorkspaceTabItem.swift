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
    var unread = false
    var pinned = false

    var accessibilityID: String {
        if let workflow { return "workflowTab-\(workflow.id)" }
        return "fileTab-\(String(id.dropFirst(5)))"
    }

    var status: String? {
        workflow.map { $0.isArchived ? "Saved history" : WorkflowFooterState(workflow: $0, now: .now).status }
    }

    var statusSymbol: String? {
        guard let workflow else { return nil }
        if workflow.isArchived { return "clock" }
        return switch workflow.status {
        case .running: workflow.isRunningAgent ? "circle.fill" : nil
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        case .interrupted: "pause.circle"
        case .cancelled: "stop.circle"
        case .exited: "circle.dotted"
        case .closed: "xmark.circle"
        }
    }

    var statusColor: Color {
        guard let workflow else { return .secondary }
        return switch workflow.status {
        case .failed: .red
        case .completed: .green
        case .running: .statusRunning
        default: .secondary
        }
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
