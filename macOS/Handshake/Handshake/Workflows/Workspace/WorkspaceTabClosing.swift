import AppKit
import SwiftUI

/// Coordinates explicit close actions, process warnings, neighbor selection, and reopen descriptors.
struct WorkspaceTabClosing {
    let coreClient: CoreClient
    let layouts: WorkflowLayouts
    let tabManagement: WorkspaceTabsModel
    let fileTabs: FileTabsModel
    let folder: String
    let sessionID: UInt64?
    let workflows: [CoreWorkflow]
    let selection: Binding<WorkflowTabSelection>
    let reportFailure: (String) -> Void

    func closeFile(_ id: UUID) {
        guard let editor = fileTabs.editors.first(where: { $0.id == id }) else { return }
        let reference = WorkspaceTabsModel.file(editor.path)
        let arrangement = tabManagement.arrangement(sessionID)
        let closed = WorkspaceTabsModel.ClosedTab(
            title: editor.displayName, sessionID: sessionID,
            file: .init(
                path: editor.path, folder: editor.folder, memoryRequest: editor.memoryRequest,
                source: editor.memorySource), reference: reference,
            index: arrangement.order.firstIndex(of: reference) ?? arrangement.order.count,
            pinned: arrangement.pins.contains(reference))
        let next = WorkspaceTabsModel.neighbor(in: displayedTabReferences, closing: [reference], selected: reference)
        let wasSelected = fileTabs.selectedID == id
        if fileTabs.close(id) {
            tabManagement.rememberClosed(closed)
            if wasSelected { selectTabReference(next) }
        }
    }

    private var displayedTabReferences: [String] {
        tabManagement.ordered(
            workflows.filter { layouts.splitRoot(for: $0.id, in: folder, workflows: workflows) == $0.id }.map {
                WorkspaceTabsModel.workflow($0.id)
            }
                + fileTabs.editors.map { WorkspaceTabsModel.file($0.path) }, session: sessionID)
    }

    private func selectTabReference(_ reference: String?) {
        let editor = fileTabs.editors.first { WorkspaceTabsModel.file($0.path) == reference }
        if let editor {
            fileTabs.select(editor.id)
        } else {
            fileTabs.showWorkflows()
            selection.wrappedValue.selectedID = reference.flatMap { UInt64($0.dropFirst(9)) }
        }
    }

    func closeWorkflows(_ ids: [UInt64], root: UInt64) {
        guard let workflow = workflows.first(where: { $0.id == root }) else { return }
        if workflows.contains(where: { ids.contains($0.id) && $0.isRunningAgent }) {
            let alert = NSAlert()
            alert.messageText = ids.count > 1 ? "Close this tab and its panes?" : "Close this tab?"
            alert.informativeText =
                "Running agents will stop. You can reopen saved history, but processes will not restart automatically."
            alert.addButton(withTitle: "Close and Stop Agents")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let reference = WorkspaceTabsModel.workflow(root)
        let arrangement = tabManagement.arrangement(sessionID)
        let targetSession = sessionID
        let layout = layouts.layout(for: root, in: folder)
        let groupRoot = layouts.splitRoot(for: root, in: folder, workflows: workflows)
        let promoted =
            groupRoot == root ? layouts.terminalSplit(for: root, in: folder).ids.first { !ids.contains($0) } : nil
        if fileTabs.selectedID == nil, let selected = selection.wrappedValue.selectedID, ids.contains(selected) {
            let splitRoot = layouts.splitRoot(for: selected, in: folder, workflows: workflows)
            if let sibling = layouts.terminalSplit(for: splitRoot, in: folder).ids.first(where: { !ids.contains($0) }) {
                selection.wrappedValue.selectedID = sibling
            } else {
                selectTabReference(
                    WorkspaceTabsModel.neighbor(
                        in: displayedTabReferences, closing: Set(ids.map(WorkspaceTabsModel.workflow)),
                        selected: WorkspaceTabsModel.workflow(splitRoot)))
            }
        }
        Task {
            var closedIDs: [UInt64] = []
            do {
                for id in ids {
                    try await coreClient.closeWorkflow(workflowID: id)
                    closedIDs.append(id)
                }
            } catch { reportFailure(error.localizedDescription) }
            if closedIDs.contains(root), let promoted {
                tabManagement.promote(
                    reference, to: WorkspaceTabsModel.workflow(promoted), previous: arrangement, session: targetSession)
            }
            if !closedIDs.isEmpty {
                tabManagement.rememberClosed(
                    .init(
                        title: workflow.customName ?? workflow.name, sessionID: targetSession,
                        workflowIDs: closedIDs, layout: closedIDs.count == ids.count ? layout : nil,
                        reference: WorkspaceTabsModel.workflow(closedIDs[0]),
                        index: arrangement.order.firstIndex(of: reference) ?? arrangement.order.count,
                        pinned: arrangement.pins.contains(reference)))
            }
        }
    }

}
