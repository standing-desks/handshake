import OSLog
import SwiftUI

private let tabLogger = Logger(subsystem: "com.twineproject.Twine", category: "tabs")

/// Builds any session's tabs from the window's workflows, files, and browser pages.
struct WorkspaceTabCatalog {
    let model: WorkspaceTabsModel
    let files: FileTabsModel
    let browsers: BrowserTabsModel
    let layouts: WorkflowLayouts
    let folder: String

    /// A session's tabs, finding its tab workflows (one per split) among the folder's workflows.
    func items(session: UInt64, among workflows: [CoreWorkflow]) -> [WorkspaceTabItem] {
        let sessionWorkflows = workflows.filter { $0.sessionID == session }
        let roots = sessionWorkflows.filter {
            layouts.splitRoot(for: $0.id, in: folder, workflows: sessionWorkflows) == $0.id
        }
        return WorkspaceTabItem.items(
            session: session, workflows: roots, files: files, browsers: browsers, model: model)
    }
}

/// Selects and moves tabs by reference, for the tab bar, the sidebar, and the tab switcher.
struct WorkspaceTabNavigator {
    let client: CoreClient
    let model: WorkspaceTabsModel
    let files: FileTabsModel
    let browsers: BrowserTabsModel
    let layouts: WorkflowLayouts
    let folder: String
    let selection: Binding<WorkflowTabSelection>
    let currentSession: UInt64?

    var catalog: WorkspaceTabCatalog {
        WorkspaceTabCatalog(model: model, files: files, browsers: browsers, layouts: layouts, folder: folder)
    }

    private var workflows: [CoreWorkflow] { client.snapshot?.workflows.workflows ?? [] }

    /// The current session's selected tab.
    var selectedReference: String? {
        if let browser = browsers.selected { return WorkspaceTabsModel.browser(browser.id) }
        if let editor = files.selected { return WorkspaceTabsModel.file(editor.path) }
        guard let id = selection.wrappedValue.selectedID else { return nil }
        return WorkspaceTabsModel.workflow(layouts.splitRoot(for: id, in: folder, workflows: workflows))
    }

    /// The placement that puts a tab back where it is now in its session.
    private func placement(of reference: String, in session: UInt64) -> TabPlacement {
        let order = catalog.items(session: session, among: workflows).map(\.id)
        guard let index = order.firstIndex(of: reference), index + 1 < order.count else { return .end }
        return .before(order[index + 1])
    }

    /// Lets ⌘Z send a tab that moved between sessions back where it was, and ⌘⇧Z move it again.
    private func registerUndo(
        of reference: String, from source: UInt64, to destination: UInt64, returningTo placement: TabPlacement,
        undoManager: UndoManager?
    ) {
        guard let undoManager, source != destination else { return }
        undoManager.registerUndo(withTarget: model) { _ in
            // The navigator that registered this may describe an older session, so start from the current one.
            let current = WorkspaceTabNavigator(
                client: client, model: model, files: files, browsers: browsers, layouts: layouts, folder: folder,
                selection: selection, currentSession: client.snapshot?.workflows.session?.id)
            // Registering the reverse move while undoing makes it the redo.
            current.registerUndo(
                of: reference, from: destination, to: source,
                returningTo: current.placement(of: reference, in: destination), undoManager: undoManager)
            let isSelected = current.currentSession == destination && current.selectedReference == reference
            Task {
                do {
                    try await current.move(
                        reference, from: destination, to: source, at: placement, isSelected: isSelected)
                } catch {
                    tabLogger.error("Could not undo a tab move: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        undoManager.setActionName("Move Tab")
    }

    /// Shows a tab. A tab in another session selects that session first; preparing the session's tabs then
    /// restores its saved selection.
    func select(_ reference: String, in session: UInt64?) async throws {
        guard let session, session != currentSession else {
            show(reference)
            return
        }
        model.select(reference, session: session)
        try await client.selectSession(sessionID: session)
    }

    /// Shows a tab of the current session.
    func show(_ reference: String) {
        if reference.hasPrefix("workflow:"), let id = UInt64(reference.dropFirst(9)) {
            files.showWorkflows()
            selection.wrappedValue.selectedID = id
        } else if reference.hasPrefix("browser:"), let id = UUID(uuidString: String(reference.dropFirst(8))) {
            browsers.select(id)
        } else if let editor = files.editors.first(where: { WorkspaceTabsModel.file($0.path) == reference }) {
            files.select(editor.id)
        }
    }

    /// Moves a tab within its session or to another one, and lets ⌘Z send it back when it changed sessions. A
    /// file that merges into a tab the destination already holds can't be separated again, so that move isn't
    /// undoable.
    func move(
        _ reference: String, from source: UInt64, to destination: UInt64, at placement: TabPlacement = .end,
        undoManager: UndoManager?
    ) async throws {
        let returning = self.placement(of: reference, in: source)
        let merges = WorkspaceTabsModel.isPage(reference) && model.holds(reference, session: destination)
        try await move(
            reference, from: source, to: destination, at: placement,
            isSelected: currentSession == source && selectedReference == reference)
        if !merges {
            registerUndo(of: reference, from: source, to: destination, returningTo: returning, undoManager: undoManager)
        }
    }

    /// Workflows move in core with every pane of their split; files and browser pages move between session
    /// arrangements. A selected tab stays selected, so its new session becomes the current one.
    private func move(
        _ reference: String, from source: UInt64, to destination: UInt64, at placement: TabPlacement,
        isSelected: Bool
    ) async throws {
        let destinationReferences = catalog.items(session: destination, among: workflows).map(\.id)
        if source != destination, reference.hasPrefix("workflow:"), let root = UInt64(reference.dropFirst(9)) {
            var moved: [UInt64] = []
            do {
                for id in layouts.terminalSplit(for: root, in: folder).ids {
                    try await client.moveWorkflow(workflowID: id, sessionID: destination)
                    moved.append(id)
                }
            } catch {
                // A split stays together: panes that already moved go back before the failure is reported.
                for id in moved { try? await client.moveWorkflow(workflowID: id, sessionID: source) }
                throw error
            }
        }
        // A file the destination already holds merges into that tab, which has the same reference.
        model.transfer(reference, from: source, to: destination, at: placement, references: destinationReferences)
        guard source != destination, isSelected else { return }
        try await select(reference, in: destination)
    }
}
