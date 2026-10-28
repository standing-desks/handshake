import SwiftUI

/// Composes tab presentation and commands without owning the workflow or terminal lifetimes.
struct WorkspaceTabBar: View {
    @Environment(CoreClient.self) private var client
    @Environment(FileTabsModel.self) private var files
    @Environment(BrowserTabsModel.self) private var browsers
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
    @State private var renaming: WorkspaceTabItem?
    @State private var preparedSession: UInt64?
    @State private var prepared = false
    @State private var reopening = false

    private var selected: String? {
        if let browser = browsers.selected { return WorkspaceTabsModel.browser(browser.id) }
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
            return WorkspaceTabItem(
                id: id, title: workflowTitles[workflow.id] ?? workflow.name,
                detail: detail, symbol: workflow.tabSymbol, workflow: workflow,
                pinned: pins.contains(id))
        }
        items += files.editors.map { editor in
            let id = WorkspaceTabsModel.file(editor.path)
            return WorkspaceTabItem(
                id: id, title: fileTitles[editor.id] ?? editor.displayName, detail: editor.path,
                symbol: "doc.text", fileID: editor.id, isDirty: editor.isDirty, pinned: pins.contains(id))
        }
        let browserTitles = WorkspaceTabItem.browserTitles(browsers.tabs)
        items += browsers.tabs.map { tab in
            let id = WorkspaceTabsModel.browser(tab.id)
            return WorkspaceTabItem(
                id: id, title: browserTitles[tab.id] ?? tab.title, detail: tab.address, symbol: "globe",
                browser: tab, pinned: pins.contains(id))
        }
        let lookup = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return model.ordered(items.map(\.id), session: sessionID).compactMap { lookup[$0] }
    }

    private var selectedItem: WorkspaceTabItem? { items.first { $0.id == selected } }
    private var references: [String] { items.map(\.id) }
    private var visibleIDs: Set<UInt64> {
        guard files.contentSelection.content == nil, let selectedRoot else { return [] }
        return Set(layouts.terminalSplit(for: selectedRoot, in: folder).ids)
    }

    var body: some View {
        ManagedWorkflowTabs(
            items: items, selected: selected, dragScope: model.dragScope, showsSwitcher: $model.showsSwitcher,
            select: select, close: closeItem, rename: { renaming = $0 },
            resetName: { item in Task { await rename(item, name: nil) } },
            pin: { model.togglePin($0, session: sessionID) },
            move: { model.move($0, by: $1, references: references, session: sessionID) },
            drop: { model.place($0, relativeTo: $1, after: $2, references: references, session: sessionID) },
            cancel: cancel, create: create, reopen: reopen,
            canReopen: !reopening && !model.recentlyClosed(session: sessionID).isEmpty
        )
        .focusedSceneValue(\.tabActions, actions)
        .sheet(item: $renaming) { item in
            TabRenameSheet(name: item.renameValue) { name in
                if let workflow = item.workflow {
                    try await client.renameWorkflow(workflowID: workflow.id, name: name)
                } else if let browser = item.browser {
                    browser.customName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            .appZoom()
        }
        .task(id: sessionID) {
            // Core teardown can clear the session after presentation snapshots have been saved.
            guard !Task.isCancelled, !files.isClosingPresentation else { return }
            prepared = false
            browsers.configure(folder: folder)
            prepareBrowsers()
            let keepsBrowser = browsers.selected != nil
            let savedSelection = model.arrangement(sessionID).selection
            model.restoreFiles(into: files)
            if !keepsBrowser, let savedSelection, references.contains(savedSelection) {
                select(savedSelection)
            } else if !keepsBrowser && preparedSession != sessionID {
                files.showWorkflows()
            }
            preparedSession = sessionID
            prepared = true
            model.reconcile(references, session: sessionID)
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
        }
        .onChange(of: references) { prepareBrowsers() }
        .onDisappear { browsers.willClose = nil }
    }

    private var actions: TabActions {
        let reopenAction: (() -> Void)? =
            !reopening && !model.recentlyClosed(session: sessionID).isEmpty ? { reopen() } : nil
        let renameAction: (() -> Void)? = selectedItem.flatMap { item in
            item.canRename ? { renaming = item } : nil
        }
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
        } else if let browser = item.browser {
            browsers.select(browser.id)
        } else if let id = item.fileID {
            files.select(id)
        }
    }

    private func closeItem(_ item: WorkspaceTabItem) {
        if let workflow = item.workflow {
            close(workflow.id)
        } else if let browser = item.browser {
            browsers.close(browser.id)
        } else if let id = item.fileID {
            closeFile(id)
        }
    }

    private func rename(_ item: WorkspaceTabItem, name: String?) async {
        if let browser = item.browser {
            browser.customName = name
            return
        }
        guard let workflow = item.workflow else { return }
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
                if let browser = closed.browser {
                    browsers.restore(browser)
                } else if let file = closed.file {
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

    private func prepareBrowsers() {
        browsers.visualOrder = items.compactMap { $0.browser?.id }
        let session = sessionID
        browsers.willClose = { [weak model] tab in
            guard let model else { return }
            let reference = WorkspaceTabsModel.browser(tab.id)
            let arrangement = model.arrangement(session)
            model.rememberClosed(
                .init(
                    title: tab.title, sessionID: session, browser: tab.snapshot, reference: reference,
                    index: arrangement.order.firstIndex(of: reference) ?? arrangement.order.count,
                    pinned: arrangement.pins.contains(reference)))
        }
    }

    private var contextIsCurrent: Bool {
        client.snapshot?.folders.openFolder == folder && client.snapshot?.workflows.session?.id == sessionID
    }
}
