import SwiftUI

/// The strip shares no state with terminal views, so dragging never remounts a terminal.
struct ManagedWorkflowTabs: View {
    @TerminalTheme private var palette
    @Environment(\.appZoom) private var zoom
    let items: [WorkspaceTabItem]
    let selected: String?
    let dragScope: String
    @Binding var showsSwitcher: Bool
    let select: (String) -> Void
    let close: (WorkspaceTabItem) -> Void
    let rename: (WorkspaceTabItem) -> Void
    let resetName: (WorkspaceTabItem) -> Void
    let pin: (String) -> Void
    let move: (String, Int) -> Void
    let drop: @MainActor @Sendable (String, String, Bool) -> Void
    let cancel: (UInt64) -> Void
    let create: () -> Void
    let reopen: () -> Void
    let canReopen: Bool
    /// The folder's other sessions, which a tab can move to.
    var sessionTargets: [CoreSession] = []
    var moveToSession: (WorkspaceTabItem, UInt64) -> Void = { _, _ in }
    var switchLayout: () -> Void = {}
    @State private var dragging: String?
    @State private var insertion: String?
    @State private var insertionAfter = false
    @State private var scrollEdge = 0
    @State private var viewport = WorkspaceTabViewport()

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Text("TABS").sectionLabelStyle().fixedSize().frame(height: WorkflowTabLayout.height)
            WorkspaceTabScrollView(
                viewport: viewport, selected: selected, references: items.map(\.id), isDragging: dragging != nil,
                coordinateSpace: dragScope
            ) {
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(items) { item in
                        tab(item)
                            .background(WorkspaceTabScrollTarget(viewport: viewport, reference: item.id))
                            .highPriorityGesture(
                                DragGesture(minimumDistance: 5, coordinateSpace: .named(dragScope))
                                    .onChanged { updateDrag(item, location: $0.location) }
                                    .onEnded { finishDrag(item, location: $0.location) }
                            )
                            .overlay(alignment: insertionAfter ? .trailing : .leading) {
                                if insertion == item.id {
                                    Rectangle().fill(.tint).frame(width: 2).padding(.vertical, 3)
                                }
                            }
                    }
                }
                .padding(.horizontal, 1)
                .fixedSize(horizontal: true, vertical: false)
            }
            .onChange(of: items.map(\.id)) {
                if let dragging, !items.contains(where: { $0.id == dragging }) { cancelDrag() }
            }
            .task(id: scrollEdge) {
                guard scrollEdge != 0 else { return }
                var index =
                    items.firstIndex { $0.id == insertion || $0.id == dragging }
                    ?? (scrollEdge < 0 ? items.count : 0)
                while !Task.isCancelled && scrollEdge != 0 && dragging != nil {
                    index = min(max(index + scrollEdge, 0), max(0, items.count - 1))
                    if items.indices.contains(index) { viewport.reveal(items[index].id) }
                    try? await Task.sleep(for: .milliseconds(180))
                }
            }
            .layoutPriority(1)
            Button(action: create) {
                Label("New Workflow", systemImage: "plus")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .labelStyle(.iconOnly).workspaceBarControl()
            .frame(width: WorkflowTabLayout.creationButtonWidth)
            .help("New Workflow (⌘T)").accessibilityIdentifier("newWorkflow")
            NewBrowserTabButton()
            Spacer(minLength: 0)
            Button {
                showsSwitcher.toggle()
            } label: {
                Label("Find Open Tab", systemImage: "square.on.square")
                    .frame(maxHeight: .infinity)
            }
            .labelStyle(.iconOnly).workspaceBarControl()
            .fixedSize(horizontal: true, vertical: false)
            .help("Find an Open Tab (⇧⌘A) — \(items.count) tabs")
            .accessibilityLabel("Find an open tab, \(items.count) tabs")
            .accessibilityIdentifier("tabSwitcher")
            .popover(isPresented: $showsSwitcher) {
                WorkspaceTabSwitcher(items: items, selected: selected, select: select).appZoom()
            }
        }
        .frame(height: WorkflowTabLayout.height, alignment: .bottom)
        .contextMenu {
            Button("Reopen Closed Tab", action: reopen).disabled(!canReopen)
            Divider()
            Button(TabLayout.top.toggleTitle, systemImage: "sidebar.left", action: switchLayout)
        }
    }

    private func tab(_ item: WorkspaceTabItem) -> some View {
        WorkspaceTab(
            name: item.title, symbol: item.pinned ? "pin.fill" : item.symbol,
            tabID: item.accessibilityID,
            closeID: item.closeID,
            helpText: [item.title, item.detail, item.status].compactMap { $0 }.joined(separator: "\n"),
            fill: tabFill(item),
            selectedForeground: item.workflow == nil ? nil : Color(nsColor: palette.text),
            isEdited: item.isDirty, statusSymbol: item.statusSymbol, statusColor: item.statusColor,
            statusDescription: item.status, pinned: item.pinned,
            doubleClick: item.canRename ? { rename(item) } : nil,
            isSelected: item.id == selected, select: { select(item.id) }, close: { close(item) }
        )
        .contextMenu {
            if item.canRename {
                Button("Rename…", systemImage: "pencil") { rename(item) }
                Button("Reset Name") { resetName(item) }.disabled(item.customName == nil)
            }
            Button(item.pinned ? "Unpin Tab" : "Pin Tab", systemImage: item.pinned ? "pin.slash" : "pin") {
                pin(item.id)
            }
            if !sessionTargets.isEmpty {
                Menu("Move to Session", systemImage: "arrow.right") {
                    ForEach(sessionTargets) { session in
                        Button(session.name) { moveToSession(item, session.id) }
                    }
                }
            }
            Divider()
            Button("Move Left") { move(item.id, -1) }
            Button("Move Right") { move(item.id, 1) }
            Divider()
            if let workflow = item.workflow, workflow.isRunningAgent {
                Button("Cancel Agent", systemImage: "stop.circle") { cancel(workflow.id) }
            }
            Button("Close Tab", systemImage: "xmark") { close(item) }
            Button("Reopen Closed Tab", action: reopen).disabled(!canReopen)
            Divider()
            Button(TabLayout.top.toggleTitle, systemImage: "sidebar.left", action: switchLayout)
        }
        .accessibilityAction(named: "Move Left") { move(item.id, -1) }
        .accessibilityAction(named: "Move Right") { move(item.id, 1) }
    }

    private func tabFill(_ item: WorkspaceTabItem) -> Color {
        item.workflow == nil ? Color(nsColor: .textBackgroundColor) : Color(nsColor: palette.background)
    }

    private func updateDrag(_ item: WorkspaceTabItem, location: CGPoint) {
        dragging = item.id
        let scale = zoom?.scale ?? 1
        guard location.y >= -16 * scale && location.y <= (WorkflowTabLayout.height + 16) * scale else {
            insertion = nil
            scrollEdge = 0
            return
        }
        let candidates = items.filter { $0.pinned == item.pinned && viewport.frame(for: $0.id) != nil }
        let contentX = location.x
        let target = candidates.min {
            abs((viewport.frame(for: $0.id)?.midX ?? 0) - contentX)
                < abs((viewport.frame(for: $1.id)?.midX ?? 0) - contentX)
        }
        insertion = target?.id
        insertionAfter = target.flatMap { viewport.frame(for: $0.id) }.map { contentX > $0.midX } ?? false
        scrollEdge =
            location.x < viewport.visibleRect.minX + 24 * scale
            ? -1 : (location.x > viewport.visibleRect.maxX - 24 * scale ? 1 : 0)
    }

    private func finishDrag(_ item: WorkspaceTabItem, location: CGPoint) {
        defer { cancelDrag() }
        guard location.x >= viewport.visibleRect.minX && location.x <= viewport.visibleRect.maxX else { return }
        updateDrag(item, location: location)
        if let insertion { drop(item.id, insertion, insertionAfter) }
    }

    private func cancelDrag() {
        dragging = nil
        insertion = nil
        scrollEdge = 0
    }
}
