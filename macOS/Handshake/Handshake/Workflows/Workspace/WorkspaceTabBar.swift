import SwiftUI

/// Composes tab presentation and commands without owning the workflow or terminal lifetimes.
struct WorkspaceTabBar: View {
    @Environment(CoreClient.self) private var client
    @Environment(FileTabsModel.self) private var files
    @Environment(WorkflowLayouts.self) private var layouts
    @Bindable var model: WorkspaceTabsModel
    let folder: String
    let sessionID: UInt64?
    let workflows: [CoreWorkflow]
    let tabWorkflows: [CoreWorkflow]
    let selectedRoot: UInt64?
    @Binding var selection: WorkflowTabSelection
    let close: (UInt64) -> Void
    let closeFile: (UUID) -> Void
    let cancel: (UInt64) -> Void
    let create: () -> Void
    let reportFailure: (String) -> Void
    @State private var renaming: CoreWorkflow?
    @State private var preparedSession: UInt64?
    @State private var prepared = false
    @State private var reopening = false

    private var selected: String? {
        if let editor = files.selected { return WorkspaceTabsModel.file(editor.path) }
        return selectedRoot.map(WorkspaceTabsModel.workflow)
    }

    private var items: [WorkspaceTabItem] {
        let workflowTitles = WorkspaceTabItem.workflowTitles(tabWorkflows)
        let fileTitles = WorkspaceTabItem.fileTitles(files.editors)
        let pins = model.arrangement(sessionID).pins
        var items = tabWorkflows.map { workflow in
            let id = WorkspaceTabsModel.workflow(workflow.id)
            let harnesses = workflow.run?.agents.map { $0.harness.displayName } ?? []
            let detail =
                ([workflow.name, workflow.harness?.displayName].compactMap { $0 } + Array(Set(harnesses)).sorted())
                .joined(separator: " · ")
            let group = layouts.terminalSplit(for: workflow.id, in: folder).ids
            return WorkspaceTabItem(
                id: id, title: workflowTitles[workflow.id] ?? workflow.name,
                detail: detail, symbol: workflow.tabSymbol, workflow: workflow,
                unread: !model.unread.isDisjoint(with: group), pinned: pins.contains(id))
        }
        items += files.editors.map { editor in
            let id = WorkspaceTabsModel.file(editor.path)
            return WorkspaceTabItem(
                id: id, title: fileTitles[editor.id] ?? editor.displayName, detail: editor.path,
                symbol: "doc.text", fileID: editor.id, isDirty: editor.isDirty, pinned: pins.contains(id))
        }
        let lookup = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return model.ordered(items.map(\.id), session: sessionID).compactMap { lookup[$0] }
    }

    private var selectedItem: WorkspaceTabItem? { items.first { $0.id == selected } }
    private var references: [String] { items.map(\.id) }
    private var visibleIDs: Set<UInt64> {
        guard files.selected == nil, let selectedRoot else { return [] }
        return Set(layouts.terminalSplit(for: selectedRoot, in: folder).ids)
    }

    var body: some View {
        ManagedWorkflowTabs(
            items: items, selected: selected, dragScope: model.dragScope, showsSwitcher: $model.showsSwitcher,
            select: select, close: closeItem, rename: { renaming = $0 },
            resetName: { workflow in Task { await rename(workflow, name: nil) } },
            pin: { model.togglePin($0, session: sessionID) },
            move: { model.move($0, by: $1, references: references, session: sessionID) },
            drop: { model.place($0, relativeTo: $1, after: $2, references: references, session: sessionID) },
            cancel: cancel, create: create, reopen: reopen,
            canReopen: !reopening && !model.recentlyClosed(session: sessionID).isEmpty
        )
        .focusedSceneValue(\.tabActions, actions)
        .sheet(item: $renaming) { workflow in
            TabRenameSheet(workflow: workflow) { name in
                try await client.renameWorkflow(workflowID: workflow.id, name: name)
            }
            .appZoom()
        }
        .task(id: sessionID) {
            prepared = false
            let savedSelection = model.arrangement(sessionID).selection
            model.restoreFiles(into: files)
            if let savedSelection, references.contains(savedSelection) {
                select(savedSelection)
            } else if preparedSession != sessionID {
                files.showWorkflows()
            }
            preparedSession = sessionID
            prepared = true
            model.reconcile(references, session: sessionID)
            model.observe(workflows, visibleIDs: visibleIDs)
            for editor in files.editors where editor.memoryRequest != nil && editor.baseline == nil {
                do { try await files.refreshMemory(editor, client: client) } catch {
                    if !Task.isCancelled { reportFailure(error.localizedDescription) }
                }
            }
        }
        .onChange(of: references) {
            if !files.isClosingPresentation { model.reconcile(references, session: sessionID) }
        }
        .onChange(of: files.editors.map(\.path)) {
            if !files.isClosingPresentation { model.rememberFiles(files.editors) }
        }
        .onChange(of: selected) {
            if prepared && preparedSession == sessionID && !files.isClosingPresentation {
                model.select(selected, session: sessionID)
            }
            model.observe(workflows, visibleIDs: visibleIDs)
        }
        .onChange(of: workflows) { model.observe(workflows, visibleIDs: visibleIDs) }
    }

    private var actions: TabActions {
        let reopenAction: (() -> Void)? =
            !reopening && !model.recentlyClosed(session: sessionID).isEmpty ? { reopen() } : nil
        let renameAction: (() -> Void)? = selectedItem?.workflow.map { workflow in { renaming = workflow } }
        let pinAction: (() -> Void)? = selected.map { reference in { model.togglePin(reference, session: sessionID) } }
        let moveAction: ((Int) -> Void)? = selected.map { reference in
            { (offset: Int) in model.move(reference, by: offset, references: references, session: sessionID) }
        }
        let closeAction: (() -> Void)? = selectedItem.map { item in { closeItem(item) } }
        return TabActions(
            moveSelection: { offset in
                guard !items.isEmpty else { return }
                let index = items.firstIndex { $0.id == selected } ?? 0
                select(items[(index + offset + items.count) % items.count].id)
            },
            selectIndex: { index in if items.indices.contains(index) { select(items[index].id) } },
            showSwitcher: { model.showsSwitcher = true },
            reopen: reopenAction,
            rename: renameAction,
            pin: pinAction,
            move: moveAction,
            closeTab: closeAction,
            closeTitle: visibleIDs.count > 1 ? "Close Pane" : "Close Tab"
        )
    }

    private func select(_ reference: String) {
        guard let item = items.first(where: { $0.id == reference }) else { return }
        if let workflow = item.workflow {
            files.showWorkflows()
            selection.selectedID = workflow.id
        } else if let id = item.fileID {
            files.select(id)
        }
    }

    private func closeItem(_ item: WorkspaceTabItem) {
        if let workflow = item.workflow { close(workflow.id) } else if let id = item.fileID { closeFile(id) }
    }

    private func rename(_ workflow: CoreWorkflow, name: String?) async {
        do { try await client.renameWorkflow(workflowID: workflow.id, name: name) } catch {
            reportFailure(error.localizedDescription)
        }
    }

    private func reopen() {
        guard !reopening, let closed = model.recentlyClosed(session: sessionID).first else { return }
        reopening = true
        Task {
            defer { reopening = false }
            do {
                if let file = closed.file {
                    let editor = files.restore(
                        path: file.path, folder: file.folder, memoryRequest: file.memoryRequest, source: file.source)
                    files.select(editor.id)
                    if editor.memoryRequest != nil { try await files.refreshMemory(editor, client: client) }
                } else {
                    for id in closed.workflowIDs
                    where client.snapshot?.workflows.workflows.contains(where: { $0.id == id }) != true {
                        try await client.reopenWorkflow(workflowID: id)
                    }
                    if let id = closed.workflowIDs.first, contextIsCurrent {
                        if let layout = closed.layout { layouts.setLayout(layout, for: id, in: folder) }
                        files.showWorkflows()
                        selection.selectedID = id
                    }
                }
                model.didReopen(closed, session: sessionID)
            } catch { if contextIsCurrent { reportFailure(error.localizedDescription) } }
        }
    }

    private var contextIsCurrent: Bool {
        client.snapshot?.folders.openFolder == folder && client.snapshot?.workflows.session?.id == sessionID
    }
}
