import SwiftUI

/// The strip shares no state with terminal views, so dragging never remounts a terminal.
struct ManagedWorkflowTabs: View {
    @TerminalTheme private var palette
    @Environment(\.effectiveReduceMotion) private var reduceMotion
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
    @State private var frames: [String: CGRect] = [:]
    @State private var viewportWidth: CGFloat = 0
    @State private var tabsWidth: CGFloat?
    @State private var scrollEdge = 0

    private struct ScrollWidths: Equatable {
        let content: CGFloat
        let viewport: CGFloat
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Text("TABS").sectionLabelStyle().fixedSize().frame(height: WorkflowTabLayout.height)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(items) { item in
                            tab(item)
                                .id(item.id)
                                .transition(.opacity)
                                .highPriorityGesture(
                                    DragGesture(minimumDistance: 5, coordinateSpace: .named(dragScope))
                                        .onChanged { updateDrag(item, location: $0.location) }
                                        .onEnded { finishDrag(item, location: $0.location) }
                                )
                                .onGeometryChange(
                                    for: CGRect.self, of: { $0.frame(in: .named(dragScope)) },
                                    action: { frames[item.id] = $0 }
                                )
                                .overlay(alignment: insertionAfter ? .trailing : .leading) {
                                    if insertion == item.id {
                                        Rectangle().fill(.tint).frame(width: 2).padding(.vertical, 3)
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 1)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { tabsWidth = $0 })
                }
                .coordinateSpace(name: dragScope)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { viewportWidth = $0 })
                .scrollIndicators(.never)
                .onChange(of: selected) {
                    withAnimation(reduceMotion ? nil : Motion.scrollToSelectedTab) { revealSelection(using: proxy) }
                }
                .onScrollGeometryChange(
                    for: ScrollWidths.self,
                    of: { ScrollWidths(content: $0.contentSize.width, viewport: $0.containerSize.width) },
                    action: { _, _ in
                        // The native viewport can still be animating after the outer layout reports its final size.
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { revealSelection(using: proxy) }
                    }
                )
                .onChange(of: items.map(\.id)) {
                    if let dragging, !items.contains(where: { $0.id == dragging }) { cancelDrag() }
                    revealSelection(using: proxy)
                }
                .task(id: scrollEdge) {
                    guard scrollEdge != 0 else { return }
                    var index =
                        items.firstIndex { $0.id == insertion || $0.id == dragging }
                        ?? (scrollEdge < 0 ? items.count : 0)
                    while !Task.isCancelled && scrollEdge != 0 && dragging != nil {
                        index = min(max(index + scrollEdge, 0), max(0, items.count - 1))
                        if items.indices.contains(index) {
                            withAnimation(reduceMotion ? nil : Motion.scrollToSelectedTab) {
                                proxy.scrollTo(items[index].id, anchor: scrollEdge < 0 ? .leading : .trailing)
                            }
                        }
                        try? await Task.sleep(for: .milliseconds(180))
                    }
                }
            }
            .frame(maxWidth: tabsWidth)
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
                Label("\(items.count)", systemImage: "chevron.down")
                    .frame(maxHeight: .infinity)
            }
            .workspaceBarControl().help("Find an Open Tab (⌘⇧A)")
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Find an open tab, \(items.count) tabs")
            .accessibilityIdentifier("tabSwitcher")
            .popover(isPresented: $showsSwitcher) {
                WorkspaceTabSwitcher(items: items, selected: selected, select: select).appZoom()
            }
        }
        .frame(height: WorkflowTabLayout.height, alignment: .bottom)
        .animation(reduceMotion ? nil : Motion.tabChange, value: items.map(\.id))
        .contextMenu {
            Button("Reopen Closed Tab", action: reopen).disabled(!canReopen)
            Divider()
            Button(TabLayout.top.toggleTitle, systemImage: "sidebar.left", action: switchLayout)
        }
    }

    private func revealSelection(using proxy: ScrollViewProxy) {
        guard let selected else { return }
        proxy.scrollTo(selected, anchor: selected == items.last?.id ? .trailing : nil)
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
        guard location.y >= -16 && location.y <= WorkflowTabLayout.height + 16 else {
            insertion = nil
            scrollEdge = 0
            return
        }
        let candidates = items.filter { $0.pinned == item.pinned && frames[$0.id] != nil }
        let target = candidates.min {
            abs((frames[$0.id]?.midX ?? 0) - location.x) < abs((frames[$1.id]?.midX ?? 0) - location.x)
        }
        insertion = target?.id
        insertionAfter = target.flatMap { frames[$0.id] }.map { location.x > $0.midX } ?? false
        scrollEdge = location.x < 24 ? -1 : (location.x > viewportWidth - 24 ? 1 : 0)
    }

    private func finishDrag(_ item: WorkspaceTabItem, location: CGPoint) {
        defer { cancelDrag() }
        guard location.x >= 0 && location.x <= viewportWidth else { return }
        updateDrag(item, location: location)
        if let insertion { drop(item.id, insertion, insertionAfter) }
    }

    private func cancelDrag() {
        dragging = nil
        insertion = nil
        scrollEdge = 0
    }
}
