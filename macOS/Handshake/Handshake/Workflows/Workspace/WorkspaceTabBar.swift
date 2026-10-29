import SwiftUI

/// Composes tab presentation and commands without owning the workflow or terminal lifetimes. In the sidebar
/// layout the strip is hidden, but this view still prepares each session's tabs and publishes tab commands.
struct WorkspaceTabBar: View {
    @Environment(CoreClient.self) private var client
    @Environment(FileTabsModel.self) private var files
    @Environment(BrowserTabsModel.self) private var browsers
    @Environment(WorkflowLayouts.self) private var layouts
    @Environment(\.undoManager) private var undoManager
    @AppStorage(TabLayout.storageKey) private var tabLayout = TabLayout.defaultValue
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

    private var showsStrip: Bool { tabLayout == .top }

    private var sessions: [CoreSession] {
        client.snapshot?.workflows.sessions.filter { $0.folder == folder } ?? []
    }

    private var selected: String? {
        if let browser = browsers.selected { return WorkspaceTabsModel.browser(browser.id) }
        if let editor = files.selected { return WorkspaceTabsModel.file(editor.path) }
        return selectedRoot.map(WorkspaceTabsModel.workflow)
    }

    private var items: [WorkspaceTabItem] {
        WorkspaceTabItem.items(
            session: sessionID, workflows: tabWorkflows, files: files, browsers: browsers, model: model)
    }

    /// Every open file and browser tab in the window, whichever session holds it.
    private var pages: [String] {
        files.editors.map { WorkspaceTabsModel.file($0.path) } + browsers.tabs.map { WorkspaceTabsModel.browser($0.id) }
    }

    private var selectedItem: WorkspaceTabItem? { items.first { $0.id == selected } }
    private var references: [String] { items.map(\.id) }
    private var visibleIDs: Set<UInt64> {
        guard files.contentSelection.content == nil, let selectedRoot else { return [] }
        return Set(layouts.terminalSplit(for: selectedRoot, in: folder).ids)
    }

    private var navigator: WorkspaceTabNavigator {
        WorkspaceTabNavigator(
            client: client, model: model, files: files, browsers: browsers, layouts: layouts, folder: folder,
            selection: $selection, currentSession: sessionID)
    }

    var body: some View {
        Group {
            if showsStrip {
                ManagedWorkflowTabs(
                    items: items, selected: selected, dragScope: model.dragScope, showsSwitcher: $model.showsSwitcher,
                    select: select, close: closeItem, rename: { renaming = $0 },
                    resetName: { item in Task { await rename(item, name: nil) } },
                    pin: { model.togglePin($0, session: sessionID) },
                    move: { model.move($0, by: $1, references: references, session: sessionID) },
                    drop: { model.place($0, relativeTo: $1, after: $2, references: references, session: sessionID) },
                    cancel: cancel, create: create, reopen: reopen,
                    canReopen: !reopening && !model.recentlyClosed(session: sessionID).isEmpty,
                    sessionTargets: sessions.filter { $0.id != sessionID }, moveToSession: moveToSession,
                    switchLayout: { tabLayout = tabLayout.toggled }
                )
            } else {
                Color.clear.frame(height: 0).accessibilityHidden(true)
            }
        }
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
            model.restoreFiles(into: files)
            model.retainPages(Set(pages))
            adoptUnheldPages()
            prepareBrowsers()
            // Each session restores its own selection, including a file or browser tab it holds.
            let savedSelection = model.arrangement(sessionID).selection
            if let savedSelection, references.contains(savedSelection) {
                select(savedSelection)
            } else if preparedSession != sessionID {
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
        .onChange(of: pages) {
            // A tab opened from the file tree, a memory, or the browser joins the selected session, and an agent's
            // page joins its own.
            if prepared && !files.isClosingPresentation { adoptUnheldPages() }
        }
        .onChange(of: files.editors.map(\.path)) { previous, current in
            guard !files.isClosingPresentation else { return }
            model.rememberFiles(files.editors)
            for path in Set(previous).subtracting(current) { model.releaseEverywhere(WorkspaceTabsModel.file(path)) }
        }
        .onChange(of: browsers.tabs.map(\.id)) { previous, current in
            guard !browsers.isClosing else { return }
            for id in Set(previous).subtracting(current) { model.releaseEverywhere(WorkspaceTabsModel.browser(id)) }
        }
        .onChange(of: selected) {
            guard prepared && preparedSession == sessionID && !files.isClosingPresentation else { return }
            // A page opened with its selection is placed first. Opening a file another session holds shares its
            // editor with this session too, but a browser page stays with its session when an agent selects it.
            adoptUnheldPages()
            if let selected, WorkspaceTabsModel.isPage(selected), !model.holds(selected, session: sessionID) {
                guard selected.hasPrefix("file:") else { return }
                model.adopt(selected, session: sessionID)
            }
            model.select(selected, session: sessionID)
        }
        .onChange(of: sessions.map(\.id)) { _, ids in
            // An empty list only means the folder is closing or loading; it never forgets every session.
            guard prepared, !ids.isEmpty, !files.isClosingPresentation, contextIsCurrent else { return }
            model.retainSessions(Set(ids))
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
            closeTitle: visibleIDs.count > 1 ? "Close Pane" : "Close Tab",
            switcherItems: { switcherItems() },
            switcherSelection: sessionID.flatMap { session in selected.map { "\(session)|\($0)" } },
            selectSwitcherItem: { selectSwitcherItem($0) }
        )
    }

    private func select(_ reference: String) {
        guard items.contains(where: { $0.id == reference }) else { return }
        navigator.show(reference)
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

    private func moveToSession(_ item: WorkspaceTabItem, _ destination: UInt64) {
        guard let sessionID else { return }
        let navigator = navigator
        Task {
            do { try await navigator.move(item.id, from: sessionID, to: destination, undoManager: undoManager) } catch {
                reportFailure(error.localizedDescription)
            }
        }
    }

    /// Every session's tabs, each named with its session, so the switcher finds tabs in other sessions too.
    private func switcherItems() -> [WorkspaceTabItem] {
        sessions.flatMap { session in
            navigator.catalog.items(session: session.id, among: workflows).map { item in
                WorkspaceTabItem(
                    id: item.id, title: item.title,
                    detail: [session.name, item.detail].filter { !$0.isEmpty }.joined(separator: " · "),
                    symbol: item.symbol, workflow: item.workflow, fileID: item.fileID, isDirty: item.isDirty,
                    browser: item.browser, pinned: item.pinned, scope: session.id)
            }
        }
    }

    private func selectSwitcherItem(_ key: String) {
        guard let bar = key.firstIndex(of: "|"), let session = UInt64(key[..<bar]) else { return }
        let reference = String(key[key.index(after: bar)...])
        Task {
            do { try await navigator.select(reference, in: session) } catch {
                reportFailure(error.localizedDescription)
            }
        }
    }

    /// A page an agent opened joins the agent's session; any other page joins the selected session.
    private func adoptUnheldPages() {
        let owners = browsers.tabs.reduce(into: [String: UInt64]()) { owners, tab in
            owners[WorkspaceTabsModel.browser(tab.id)] = tab.agentSession
        }
        model.adoptUnheld(pages, session: sessionID, sessions: Set(sessions.map(\.id)), owners: owners)
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
}

// MARK: - Reopening and browser tabs

extension WorkspaceTabBar {
    private func reopen() {
        guard !reopening, let closed = model.recentlyClosed(session: sessionID).first else { return }
        reopening = true
        Task {
            defer { reopening = false }
            do {
                if let browser = closed.browser {
                    model.didReopen(closed, session: sessionID)
                    browsers.restore(browser)
                    return
                } else if let file = closed.file {
                    model.didReopen(closed, session: sessionID)
                    let editor = files.restore(
                        path: file.path, folder: file.folder, memoryRequest: file.memoryRequest, source: file.source)
                    files.select(editor.id)
                    if editor.memoryRequest != nil { try await files.refreshMemory(editor, client: client) }
                    return
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
            // A page closed from another session's row reopens in that session.
            let owner = model.otherHolders(of: reference, besides: nil).first ?? session
            let arrangement = model.arrangement(owner)
            model.rememberClosed(
                .init(
                    title: tab.title, sessionID: owner, browser: tab.snapshot, reference: reference,
                    index: arrangement.order.firstIndex(of: reference) ?? arrangement.order.count,
                    pinned: arrangement.pins.contains(reference)))
        }
    }

    private var contextIsCurrent: Bool {
        client.snapshot?.folders.openFolder == folder && client.snapshot?.workflows.session?.id == sessionID
    }
}
