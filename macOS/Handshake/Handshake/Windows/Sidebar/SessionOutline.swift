import SwiftUI

/// The sidebar layout's sessions, each disclosing its tabs. Tabs drag within a session and between sessions.
/// The compact form is the minimized rail: the same rows as icons, so they line up when the rail expands.
struct SessionOutline: View {
    @Environment(CoreClient.self) private var client
    @Environment(FileTabsModel.self) private var files
    @Environment(BrowserTabsModel.self) private var browsers
    @Environment(WorkflowLayouts.self) private var layouts
    @Environment(\.undoManager) private var undoManager
    @AppStorage(TabLayout.storageKey) private var tabLayout = TabLayout.defaultValue
    let folder: String
    let sessions: [CoreSession]
    let selectedSession: UInt64?
    let model: WorkspaceTabsModel
    @Binding var selection: WorkflowTabSelection
    let presentation: SidebarPresentation
    var compact = false
    @State private var drag: Drag?
    @State private var frames: [Row: CGRect] = [:]
    @State private var springLoad: Task<Void, Never>?
    private let space = "sessionOutline"

    private enum Row: Hashable {
        case session(UInt64)
        case tab(session: UInt64, reference: String)
    }

    private enum Target: Equatable {
        /// The end of a session's tabs.
        case session(UInt64)
        /// Before or after one of a session's tabs.
        case tab(session: UInt64, reference: String, after: Bool)

        var session: UInt64 {
            switch self {
            case .session(let id), .tab(let id, _, _): id
            }
        }
    }

    private struct Drag: Equatable {
        let item: WorkspaceTabItem.ID
        let title: String
        let symbol: String
        let session: UInt64
        var location: CGPoint
        var target: Target?
    }

    private var allWorkflows: [CoreWorkflow] {
        guard client.snapshot?.folders.openFolder == folder else { return [] }
        return client.snapshot?.workflows.workflows ?? []
    }

    /// The selected tab of the selected session.
    private var selectedReference: String? {
        if let browser = browsers.selected { return WorkspaceTabsModel.browser(browser.id) }
        if let editor = files.selected { return WorkspaceTabsModel.file(editor.path) }
        guard let id = selection.selectedID else { return nil }
        return WorkspaceTabsModel.workflow(layouts.splitRoot(for: id, in: folder, workflows: allWorkflows))
    }

    private var commands: SessionOutlineCommands {
        SessionOutlineCommands(
            client: client,
            navigator: WorkspaceTabNavigator(
                client: client, model: model, files: files, browsers: browsers, layouts: layouts, folder: folder,
                selection: $selection, currentSession: selectedSession),
            presentation: presentation, workflows: allWorkflows, selectedReference: selectedReference,
            undoManager: undoManager)
    }

    var body: some View {
        let commands = commands
        LazyVStack(spacing: 0) {
            ForEach(sessions) { session in
                let items = commands.items(for: session.id)
                let expanded = presentation.expandedSessions.contains(session.id)
                sessionRow(session, items: items, expanded: expanded, commands: commands)
                    .onGeometryChange(
                        for: CGRect.self, of: { $0.frame(in: .named(space)) },
                        action: { frames[.session(session.id)] = $0 }
                    )
                    .onDisappear { frames[.session(session.id)] = nil }
                if expanded {
                    ForEach(items) { item in
                        tabRow(item, session: session.id, references: items.map(\.id), commands: commands)
                            .onGeometryChange(
                                for: CGRect.self, of: { $0.frame(in: .named(space)) },
                                action: { frames[.tab(session: session.id, reference: item.id)] = $0 }
                            )
                            .onDisappear { frames[.tab(session: session.id, reference: item.id)] = nil }
                    }
                    if items.isEmpty && !compact { emptyRow(session, commands: commands) }
                }
            }
        }
        .coordinateSpace(name: space)
        .overlay(alignment: .topLeading) { dragPreview }
        .onChange(of: selectedSession, initial: true) { _, session in
            if let session { presentation.expandedSessions.insert(session) }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func sessionRow(
        _ session: CoreSession, items: [WorkspaceTabItem], expanded: Bool, commands: SessionOutlineCommands
    ) -> some View {
        let letters = SessionMonogram.letters(for: session.name, among: sessions.map(\.name))
        let activity = items.compactMap(\.activity).max()
        let isTarget = drag?.target == .session(session.id) && drag?.session != session.id
        if compact {
            RailSessionButton(
                session: session, letters: letters, isSelected: session.id == selectedSession,
                activity: expanded ? nil : activity, isDropTarget: isTarget,
                select: { commands.selectSession(session) }
            )
            .contextMenu { sessionActions(session, commands: commands) }
        } else {
            SessionRow(
                session: session, isSelected: session.id == selectedSession, monogram: letters,
                isExpanded: Binding(
                    get: { presentation.expandedSessions.contains(session.id) },
                    set: { expand in
                        if expand {
                            presentation.expandedSessions.insert(session.id)
                        } else {
                            presentation.expandedSessions.remove(session.id)
                        }
                    }),
                tabCount: items.count, activity: activity, isDropTarget: isTarget,
                select: { commands.selectSession(session) }, rename: { presentation.sessionToRename = session },
                delete: { presentation.sessionToDelete = session },
                newWorkflow: { commands.newWorkflow(in: session.id) })
        }
    }

    @ViewBuilder
    private func tabRow(
        _ item: WorkspaceTabItem, session: UInt64, references: [String], commands: SessionOutlineCommands
    ) -> some View {
        let isSelected = commands.isSelected(item, in: session)
        Group {
            if compact {
                RailTabButton(
                    item: item, isSelected: isSelected, insertion: insertion(for: item, in: session),
                    select: { commands.select(item, in: session) }
                )
                .contextMenu { tabActions(item, session: session, references: references, commands: commands) }
            } else {
                SessionTabRow(
                    item: item, isSelected: isSelected, paneCount: commands.paneCount(item),
                    insertion: insertion(for: item, in: session),
                    select: { commands.select(item, in: session) },
                    rename: item.canRename ? { presentation.tabToRename = item } : nil,
                    close: { commands.close(item, in: session) },
                    actions: { tabActions(item, session: session, references: references, commands: commands) })
            }
        }
        .opacity(drag?.item == item.id && drag?.session == session ? 0.4 : 1)
        .highPriorityGesture(
            DragGesture(minimumDistance: 5, coordinateSpace: .named(space))
                .onChanged { updateDrag(item, session: session, location: $0.location) }
                .onEnded { _ in finishDrag(commands: commands) }
        )
    }

    private func emptyRow(_ session: CoreSession, commands: SessionOutlineCommands) -> some View {
        HStack {
            Text("No open tabs").foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            Button("New Workflow") { commands.newWorkflow(in: session.id) }
                .buttonStyle(.link).font(.caption)
                .accessibilityIdentifier("sessionEmptyNewWorkflow-\(session.id)")
        }
        .font(.system(size: SidebarLayout.rowFontSize))
        .padding(.leading, SidebarLayout.tabRowIndent).padding(.trailing, SidebarLayout.rowInset)
        .frame(height: SidebarLayout.tabRowHeight)
    }

    /// Where the dragged tab would land beside this row.
    private func insertion(for item: WorkspaceTabItem, in session: UInt64) -> VerticalEdge? {
        guard case .tab(let target, let reference, let after)? = drag?.target, target == session,
            reference == item.id, !(drag?.item == item.id && drag?.session == session)
        else { return nil }
        return after ? .bottom : .top
    }

    @ViewBuilder private var dragPreview: some View {
        if let drag {
            let destination = drag.target.flatMap { target in
                target.session == drag.session ? nil : sessions.first { $0.id == target.session }?.name
            }
            HStack(spacing: 6) {
                Image(systemName: drag.symbol).foregroundStyle(.secondary)
                Text(drag.title).lineLimit(1)
                if let destination {
                    Text("→ \(destination)").fontWeight(.semibold).foregroundStyle(.tint).lineLimit(1)
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.background, in: .rect(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.hairline) }
            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
            .fixedSize()
            .offset(x: drag.location.x + 12, y: drag.location.y + 10)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

extension SessionOutline {
    // MARK: - Menus

    @ViewBuilder
    private func tabActions(
        _ item: WorkspaceTabItem, session: UInt64, references: [String], commands: SessionOutlineCommands
    ) -> some View {
        if item.canRename {
            Button("Rename…", systemImage: "pencil") { presentation.tabToRename = item }
            Button("Reset Name") { commands.resetName(item) }.disabled(item.customName == nil)
        }
        Button(item.pinned ? "Unpin Tab" : "Pin Tab", systemImage: item.pinned ? "pin.slash" : "pin") {
            model.togglePin(item.id, session: session)
        }
        let targets = sessions.filter { $0.id != session }
        Menu("Move to Session", systemImage: "arrow.right") {
            ForEach(targets) { target in
                Button(target.name) { commands.move(item, from: session, to: target.id) }
            }
        }
        .disabled(targets.isEmpty)
        Divider()
        Button("Move Up", systemImage: "arrow.up") {
            model.move(item.id, by: -1, references: references, session: session)
        }
        Button("Move Down", systemImage: "arrow.down") {
            model.move(item.id, by: 1, references: references, session: session)
        }
        Divider()
        if let workflow = item.workflow, workflow.isRunningAgent {
            Button("Cancel Agent", systemImage: "stop.circle") { commands.cancelAgent(workflow.id) }
        }
        Button("Close Tab", systemImage: "xmark") { commands.close(item, in: session) }
        Divider()
        Button(TabLayout.sidebar.toggleTitle, systemImage: "rectangle.topthird.inset.filled") { tabLayout = .top }
    }

    @ViewBuilder
    private func sessionActions(_ session: CoreSession, commands: SessionOutlineCommands) -> some View {
        Button("New Workflow", systemImage: "plus") { commands.newWorkflow(in: session.id) }
        Divider()
        Button("Rename Session", systemImage: "pencil") { presentation.sessionToRename = session }
        Button("Delete Session", systemImage: "trash", role: .destructive) { presentation.sessionToDelete = session }
        Divider()
        Button(TabLayout.sidebar.toggleTitle, systemImage: "rectangle.topthird.inset.filled") { tabLayout = .top }
    }

    // MARK: - Dragging

    private func updateDrag(_ item: WorkspaceTabItem, session: UInt64, location: CGPoint) {
        if drag == nil {
            drag = Drag(
                item: item.id, title: item.title, symbol: item.pinned ? "pin.fill" : item.symbol, session: session,
                location: location)
        }
        drag?.location = location
        let hit = frames.first { $0.value.contains(location) }
        let target: Target?
        switch hit?.key {
        case .session(let id):
            target = .session(id)
        case .tab(let id, let reference) where !(id == session && reference == item.id):
            target = .tab(session: id, reference: reference, after: location.y > (hit?.value.midY ?? 0))
        default:
            target = nil
        }
        guard target != drag?.target else { return }
        drag?.target = target
        springLoad?.cancel()
        // Holding over a collapsed session discloses its tabs, so the tab can land between them.
        if case .session(let id) = target, !presentation.expandedSessions.contains(id) {
            springLoad = Task {
                try? await Task.sleep(for: SidebarLayout.springLoadDelay)
                guard !Task.isCancelled, drag?.target == .session(id) else { return }
                presentation.expandedSessions.insert(id)
            }
        }
    }

    private func finishDrag(commands: SessionOutlineCommands) {
        springLoad?.cancel()
        defer { drag = nil }
        guard let drag, let target = drag.target,
            let item = commands.items(for: drag.session).first(where: { $0.id == drag.item })
        else { return }
        switch target {
        case .session(let id):
            commands.move(item, from: drag.session, to: id)
        case .tab(let id, let reference, let after):
            commands.move(item, from: drag.session, to: id, at: after ? .after(reference) : .before(reference))
        }
    }
}
