import AppKit
import SwiftUI

/// Coordinates explicit close actions, process warnings, neighbor selection, and reopen descriptors.
struct WorkspaceTabClosing {
    let coreClient: CoreClient
    let layouts: WorkflowLayouts
    let tabManagement: WorkspaceTabsModel
    let fileTabs: FileTabsModel
    let browsers: BrowserTabsModel
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
        let wasSelected = isCurrentSession && fileTabs.selectedID == id
        // Another session that holds the file keeps its editor, and any unsaved edits, open.
        let isShared = !tabManagement.otherHolders(of: reference, besides: sessionID).isEmpty
        guard isShared || fileTabs.close(id) else { return }
        tabManagement.rememberClosed(closed)
        tabManagement.release(reference, session: sessionID)
        if wasSelected { selectTabReference(next) }
    }

    /// Closes a browser tab, selecting its neighbor in the same session rather than another session's page.
    func closeBrowser(_ id: UUID) {
        let reference = WorkspaceTabsModel.browser(id)
        let next = WorkspaceTabsModel.neighbor(in: displayedTabReferences, closing: [reference], selected: reference)
        let wasSelected = isCurrentSession && browsers.selectedID == id
        browsers.close(id)
        tabManagement.release(reference, session: sessionID)
        if wasSelected { selectTabReference(next) }
    }

    /// Closing a tab from another session's row leaves the visible selection alone.
    private var isCurrentSession: Bool { coreClient.snapshot?.workflows.session?.id == sessionID }

    private var displayedTabReferences: [String] {
        tabManagement.ordered(
            workflows.filter { layouts.splitRoot(for: $0.id, in: folder, workflows: workflows) == $0.id }.map {
                WorkspaceTabsModel.workflow($0.id)
            }
                + (fileTabs.editors.map { WorkspaceTabsModel.file($0.path) }
                + browsers.tabs.map { WorkspaceTabsModel.browser($0.id) })
                .filter { tabManagement.holds($0, session: sessionID) }, session: sessionID)
    }

    private func selectTabReference(_ reference: String?) {
        if let browser = browsers.tabs.first(where: { WorkspaceTabsModel.browser($0.id) == reference }) {
            browsers.select(browser.id)
            return
        }
        let editor = fileTabs.editors.first { WorkspaceTabsModel.file($0.path) == reference }
        if let editor {
            fileTabs.select(editor.id)
        } else {
            fileTabs.showWorkflows()
            if let id = reference.flatMap({ UInt64($0.dropFirst(9)) }) { selection.wrappedValue.selectedID = id }
        }
    }

    private func confirmClosing(_ ids: [UInt64]) -> Bool {
        if workflows.contains(where: { ids.contains($0.id) && $0.isRunningAgent }) {
            let alert = NSAlert()
            alert.messageText = ids.count > 1 ? "Close this tab and its panes?" : "Close this tab?"
            alert.informativeText =
                "Running agents will stop. You can reopen saved history, but processes will not restart automatically."
            alert.addButton(withTitle: "Close and Stop Agents")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }
        return true
    }

    func closeWorkflows(_ ids: [UInt64], root: UInt64) {
        guard let workflow = workflows.first(where: { $0.id == root }) else { return }
        guard confirmClosing(ids) else { return }
        let reference = WorkspaceTabsModel.workflow(root)
        let arrangement = tabManagement.arrangement(sessionID)
        let targetSession = sessionID
        let layout = layouts.layout(for: root, in: folder)
        let groupRoot = layouts.splitRoot(for: root, in: folder, workflows: workflows)
        let promoted =
            groupRoot == root ? layouts.terminalSplit(for: root, in: folder).ids.first { !ids.contains($0) } : nil
        let selected = selection.wrappedValue.selectedID
        if fileTabs.contentSelection.content == nil, let selected, ids.contains(selected) {
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
