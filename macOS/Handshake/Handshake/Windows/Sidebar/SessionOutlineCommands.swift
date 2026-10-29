import SwiftUI

/// What the session outline does with its rows: selecting, closing, renaming, and moving tabs and sessions.
struct SessionOutlineCommands {
    let client: CoreClient
    let navigator: WorkspaceTabNavigator
    let presentation: SidebarPresentation
    /// The folder's workflows, in every session.
    let workflows: [CoreWorkflow]
    /// The selected tab of the selected session.
    let selectedReference: String?
    /// The window's undo manager, so moving a tab between sessions can be undone.
    var undoManager: UndoManager?

    private var selectedSession: UInt64? { navigator.currentSession }

    func items(for session: UInt64) -> [WorkspaceTabItem] {
        navigator.catalog.items(session: session, among: workflows)
    }

    func paneCount(_ item: WorkspaceTabItem) -> Int {
        item.workflow.map { navigator.layouts.terminalSplit(for: $0.id, in: navigator.folder).ids.count } ?? 1
    }

    func isSelected(_ item: WorkspaceTabItem, in session: UInt64) -> Bool {
        session == selectedSession && item.id == selectedReference
    }

    func selectSession(_ session: CoreSession) {
        presentation.expandedSessions.insert(session.id)
        // The other session restores its own selection once its tabs are prepared.
        guard session.id != selectedSession else { return }
        presentation.run { try await client.selectSession(sessionID: session.id) }
    }

    func select(_ item: WorkspaceTabItem, in session: UInt64) {
        presentation.run { try await navigator.select(item.id, in: session) }
    }

    func close(_ item: WorkspaceTabItem, in session: UInt64) {
        if let workflow = item.workflow {
            let ids = navigator.layouts.terminalSplit(for: workflow.id, in: navigator.folder).ids
            closing(for: session).closeWorkflows(ids, root: workflow.id)
        } else if let browser = item.browser {
            navigator.browsers.close(browser.id)
        } else if let id = item.fileID {
            closing(for: session).closeFile(id)
        }
    }

    func resetName(_ item: WorkspaceTabItem) {
        if let browser = item.browser {
            browser.customName = nil
        } else if let workflow = item.workflow {
            presentation.run { try await client.renameWorkflow(workflowID: workflow.id, name: nil) }
        }
    }

    func move(
        _ item: WorkspaceTabItem, from source: UInt64, to destination: UInt64, at placement: TabPlacement = .end
    ) {
        presentation.expandedSessions.insert(destination)
        presentation.run { [navigator, undoManager] in
            try await navigator.move(item.id, from: source, to: destination, at: placement, undoManager: undoManager)
        }
    }

    func newWorkflow(in session: UInt64) {
        presentation.expandedSessions.insert(session)
        presentation.run {
            let id = try await client.createWorkflow(folder: navigator.folder, sessionID: session, kind: .draft)
            try await navigator.select(WorkspaceTabsModel.workflow(id), in: session)
        }
    }

    func cancelAgent(_ id: UInt64) {
        Task {
            do { try await client.cancelAgent(workflowID: id) } catch {
                // The agent can end on its own just as Cancel is chosen.
                if (error as? CoreFailure)?.isAgentNotRunning == true { return }
                presentation.failure = error.localizedDescription
            }
        }
    }

    private func closing(for session: UInt64) -> WorkspaceTabClosing {
        WorkspaceTabClosing(
            coreClient: client, layouts: navigator.layouts, tabManagement: navigator.model, fileTabs: navigator.files,
            browsers: navigator.browsers, folder: navigator.folder, sessionID: session,
            workflows: workflows.filter { $0.sessionID == session }, selection: navigator.selection,
            reportFailure: { [presentation] in presentation.failure = $0 })
    }
}
