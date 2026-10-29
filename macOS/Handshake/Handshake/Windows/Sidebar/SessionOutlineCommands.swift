import OSLog
import SwiftUI

private let outlineLogger = Logger(subsystem: "com.twineproject.Twine", category: "sessions")

/// What the session outline does with its rows: selecting, closing, renaming, and moving tabs and sessions.
struct SessionOutlineCommands {
    let client: CoreClient
    let navigator: WorkspaceTabNavigator
    let presentation: SidebarPresentation
    /// The folder's workflows, in every session.
    let workflows: [CoreWorkflow]
    /// The selected tab of the selected session.
    let selectedReference: String?
    let reportFailure: (String) -> Void
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
        run { try await client.selectSession(sessionID: session.id) }
    }

    func select(_ item: WorkspaceTabItem, in session: UInt64) {
        run { try await navigator.select(item.id, in: session) }
    }

    func close(_ item: WorkspaceTabItem, in session: UInt64) {
        if let workflow = item.workflow {
            let ids = navigator.layouts.terminalSplit(for: workflow.id, in: navigator.folder).ids
            closing(for: session).closeWorkflows(ids, root: workflow.id)
        } else if let browser = item.browser {
            closing(for: session).closeBrowser(browser.id)
        } else if let id = item.fileID {
            closing(for: session).closeFile(id)
        }
    }

    func resetName(_ item: WorkspaceTabItem) {
        if let browser = item.browser {
            browser.customName = nil
        } else if let workflow = item.workflow {
            run { try await client.renameWorkflow(workflowID: workflow.id, name: nil) }
        }
    }

    func move(
        _ item: WorkspaceTabItem, from source: UInt64, to destination: UInt64, at placement: TabPlacement = .end
    ) {
        let references = items(for: destination).map(\.id)
        let wasSelected = isSelected(item, in: source)
        let returning = navigator.placement(of: item.id, in: source)
        // A file that merges into a tab the destination already holds can't be separated again by undo.
        let merges = WorkspaceTabsModel.isPage(item.id) && navigator.model.holds(item.id, session: destination)
        presentation.expandedSessions.insert(destination)
        run { [navigator, undoManager] in
            try await navigator.move(
                item.id, from: source, to: destination, at: placement, destinationReferences: references,
                isSelected: wasSelected)
            if !merges {
                navigator.registerUndo(
                    of: item.id, from: source, to: destination, returningTo: returning, undoManager: undoManager)
            }
        }
    }

    func newWorkflow(in session: UInt64) {
        presentation.expandedSessions.insert(session)
        run {
            let id = try await client.createWorkflow(folder: navigator.folder, sessionID: session, kind: .draft)
            try await navigator.select(WorkspaceTabsModel.workflow(id), in: session)
        }
    }

    func cancelAgent(_ id: UInt64) {
        Task {
            do { try await client.cancelAgent(workflowID: id) } catch {
                // The agent can end on its own just as Cancel is chosen.
                if (error as? CoreFailure)?.isAgentNotRunning == true { return }
                reportFailure(error.localizedDescription)
            }
        }
    }

    private func closing(for session: UInt64) -> WorkspaceTabClosing {
        WorkspaceTabClosing(
            coreClient: client, layouts: navigator.layouts, tabManagement: navigator.model, fileTabs: navigator.files,
            browsers: navigator.browsers, folder: navigator.folder, sessionID: session,
            workflows: workflows.filter { $0.sessionID == session }, selection: navigator.selection,
            reportFailure: reportFailure)
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        let reportFailure = reportFailure
        Task {
            do { try await operation() } catch {
                reportFailure(error.localizedDescription)
                outlineLogger.error("Could not update tabs: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
