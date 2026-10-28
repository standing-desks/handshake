import OSLog
import SwiftUI

private let workflowLogger = Logger(subsystem: "com.twineproject.Twine", category: "workflows")

/// Every workflow stays mounted, including its output pump and terminal emulator, until it closes.
struct WorkflowWorkspace: View {
    @TerminalTheme private var palette
    @Environment(CoreClient.self) private var coreClient
    @Environment(WorkflowLayouts.self) private var layouts
    @Environment(FileTabsModel.self) private var fileTabs
    @Environment(BrowserTabsModel.self) private var browsers
    @Environment(\.appZoom) private var zoom
    let folder: String
    let tabManagement: WorkspaceTabsModel
    @Binding var selection: WorkflowTabSelection
    let files: FileBrowserModel
    let contentHeight: CGFloat
    let designerVisibilityChanged: (Set<UInt64>) -> Void
    var isPresented = true
    @State private var failureMessage: String?
    @State private var isSplitting = false
    private var scale: CGFloat { zoom?.scale ?? 1 }

    private var isVisible: Bool { isPresented && fileTabs.contentSelection.content == nil }

    private var allWorkflows: [CoreWorkflow] {
        guard coreClient.snapshot?.folders.openFolder == folder else { return [] }
        return coreClient.snapshot?.workflows.workflows ?? []
    }

    private var sessionID: UInt64? { coreClient.snapshot?.workflows.session?.sessionID }
    private var workflows: [CoreWorkflow] { allWorkflows.filter { $0.sessionID == sessionID } }
    private var selectionKey: [UInt64] { [sessionID ?? 0] + workflows.map(\.id) }
    private var selectedRoot: UInt64? {
        selection.selectedID.map { layouts.splitRoot(for: $0, in: folder, workflows: workflows) }
    }
    private var tabWorkflows: [CoreWorkflow] {
        workflows.filter { layouts.splitRoot(for: $0.id, in: folder, workflows: workflows) == $0.id }
    }

    private var canSplit: Bool {
        isVisible && !isSplitting && selectedWorkflow?.kind != .agents && selectedWorkflow?.isArchived != true
            && selectedRoot.map { layouts.terminalSplit(for: $0, in: folder).ids.count < 4 } == true
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 0) {
                WorkspaceTabBar(
                    model: tabManagement, folder: folder, sessionID: sessionID, workflows: allWorkflows,
                    tabWorkflows: tabWorkflows, selectedRoot: selectedRoot, selection: $selection,
                    close: closeGroup, closeFile: tabClosing.closeFile, cancel: cancelAgent,
                    create: { Task { await create() } }, reportFailure: { failureMessage = $0 })
                TerminalSplitControls(split: split, isEnabled: canSplit)
            }
            .appZoom()
            .zIndex(1)
            WorkspaceViewport(contentHeight: max(0, contentHeight - WorkflowTabLayout.height) * scale) {
                workspaceContent
                    .frame(height: max(0, contentHeight - WorkflowTabLayout.height))
                    .onPreferenceChange(WorkflowDesignerVisibilityKey.self, perform: designerVisibilityChanged)
                    .appZoom()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: palette.background))
            .clipShape(panelShape)
            .overlay {
                panelShape.stroke(.hairline, lineWidth: Surface.hairlineWidth)
                    .mask { Rectangle().padding(.top, Surface.hairlineWidth) }
                    .allowsHitTesting(false)
            }
            .terminalPanelShadow()
            .accessibilityIdentifier("workspaceViewport")
        }
        .task {
            selection.reconcile(sessionID: sessionID, current: workflows.map(\.id))
            if coreClient.snapshot?.workflows.sessionsInitialized == false { await create() }
        }
        .onChange(of: selectionKey) {
            selection.reconcile(sessionID: sessionID, current: workflows.map(\.id))
        }
        .onChange(of: allWorkflows.map(\.id), initial: true) {
            layouts.removeClosedWorkflows(in: folder, state: coreClient.snapshot?.workflows)
        }
        .focusedSceneValue(\.workflowActions, isPresented ? actions : nil)
        .alert(
            "Workflow Error",
            isPresented: Binding(
                get: { failureMessage != nil }, set: { if !$0 { failureMessage = nil } }
            )
        ) {
            Button("OK") { failureMessage = nil }
        } message: {
            Text(failureMessage ?? "")
        }
    }

    private var workspaceContent: some View {
        ZStack {
            if workflows.isEmpty && isVisible {
                ContentUnavailableView(
                    "No Open Tabs", systemImage: "terminal",
                    description: Text("Open a workflow with + or ⌘T.")
                        .foregroundStyle(Color(nsColor: palette.text).secondary)
                )
                .foregroundStyle(Color(nsColor: palette.text))
            }
            WorkflowPaneCanvas(
                folder: folder, workflows: allWorkflows, sessionID: sessionID,
                selection: $selection, isVisible: isVisible, reportFailure: { failureMessage = $0 },
                closePane: close)
            BrowserTabsSurface(
                isPresented: isPresented, allowsAutomaticFocus: !tabManagement.showsSwitcher)
            FileTabsSurface(
                folder: folder, failure: files.failure, isPresented: isPresented,
                allowsAutomaticFocus: !tabManagement.showsSwitcher,
                reportFailure: { failureMessage = $0 })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var actions: WorkflowActions {
        WorkflowActions(
            create: { Task { await create() } },
            createAgents: { roles in Task { await create(kind: .agents, roles: roles) } },
            close: isVisible ? selection.selectedID.map { id in { close(id) } } : nil,
            cancelAgent: workflows.first(where: { isVisible && $0.id == selection.selectedID && $0.isRunningAgent })
                .map { workflow in { cancelAgent(workflow.id) } },
            layoutMode: isVisible ? selectedWorkflow.flatMap(layoutMode(for:)) : nil,
            moveFocus: isVisible ? selectedWorkflow.flatMap(focusMover(for:)) : nil,
            splitTerminal: canSplit ? { split($0) } : nil
        )
    }

    private var panelShape: RoundedRectangle { RoundedRectangle(cornerRadius: CornerRadius.panel * scale) }

    private var selectedWorkflow: CoreWorkflow? { workflows.first { $0.id == selection.selectedID } }

    /// The workflow's layout mode, when it has agents to arrange.
    private func layoutMode(for workflow: CoreWorkflow) -> Binding<WorkflowLayout.Mode>? {
        guard workflow.showsAgentSubtabs else { return nil }
        return Binding(
            get: { layouts.layout(for: workflow.id, in: folder).mode },
            set: { mode in
                var layout = layouts.layout(for: workflow.id, in: folder)
                layout.mode = mode
                layouts.setLayout(layout, for: workflow.id, in: folder)
            })
    }

    /// Moves the keyboard between the workflow's agents, when it has more than one.
    private func focusMover(for workflow: CoreWorkflow) -> ((Int) -> Void)? {
        if let selectedRoot {
            let ids = layouts.terminalSplit(for: selectedRoot, in: folder).ids
            if ids.count > 1 {
                return { offset in
                    let index = ids.firstIndex(of: selection.selectedID ?? 0) ?? 0
                    selection.selectedID = ids[(index + offset + ids.count) % ids.count]
                }
            }
        }
        guard workflow.showsAgentSubtabs else { return nil }
        return { offset in
            var layout = layouts.layout(for: workflow.id, in: folder)
            layout.moveFocus(by: offset, in: workflow.agents)
            layouts.setLayout(layout, for: workflow.id, in: folder)
        }
    }

    private func split(_ direction: TerminalSplit.Direction) {
        guard canSplit, let root = selectedRoot, let selected = selection.selectedID else { return }
        isSplitting = true
        Task {
            defer { isSplitting = false }
            do {
                let targetSession = sessionID
                if selectedWorkflow?.kind == .draft { try await coreClient.activateWorkflow(workflowID: selected) }
                let id = try await coreClient.createWorkflow(folder: folder, sessionID: targetSession, kind: .terminal)
                guard !Task.isCancelled, targetSession == sessionID,
                    workflows.contains(where: { $0.id == selected })
                else {
                    try await coreClient.closeWorkflow(workflowID: id)
                    return
                }
                var layout = layouts.layout(for: root, in: folder)
                layout.terminalSplit = (layout.terminalSplit ?? .pane(root)).inserting(
                    id, beside: selected, direction: direction)
                layouts.setLayout(layout, for: root, in: folder)
                selection.selectedID = id
            } catch { failureMessage = error.localizedDescription }
        }
    }

    private func closeGroup(_ id: UInt64) {
        tabClosing.closeWorkflows(layouts.terminalSplit(for: id, in: folder).ids, root: id)
    }

    private var tabClosing: WorkspaceTabClosing {
        WorkspaceTabClosing(
            coreClient: coreClient, layouts: layouts, tabManagement: tabManagement,
            fileTabs: fileTabs, browsers: browsers, folder: folder, sessionID: sessionID, workflows: workflows,
            selection: $selection, reportFailure: { failureMessage = $0 })
    }

    private func create(kind: CoreWorkflow.Kind = .draft, roles: [String] = []) async {
        do {
            let targetSession = sessionID
            let id = try await coreClient.createWorkflow(
                folder: folder, sessionID: targetSession, kind: kind, roles: roles)
            if Task.isCancelled {
                try await coreClient.closeWorkflow(workflowID: id)
            } else if targetSession == sessionID || targetSession == nil {
                fileTabs.showWorkflows()
                selection.selectedID = id
            }
        } catch {
            if Task.isCancelled || coreClient.snapshot?.folders.openFolder != folder { return }
            failureMessage = error.localizedDescription
            workflowLogger.error("Could not create workflow: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func cancelAgent(_ id: UInt64) {
        Task {
            do {
                try await coreClient.cancelAgent(workflowID: id)
            } catch {
                // The agent can end on its own just as Cancel is chosen.
                if (error as? CoreFailure)?.isAgentNotRunning == true { return }
                if !workflows.contains(where: { $0.id == id && $0.isRunningAgent }) { return }
                failureMessage = error.localizedDescription
                workflowLogger.error("Could not cancel agent: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func close(_ id: UInt64) {
        tabClosing.closeWorkflows([id], root: id)
    }
}
