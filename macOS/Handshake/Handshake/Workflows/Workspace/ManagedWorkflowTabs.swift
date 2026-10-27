import SwiftUI

/// The experimental strip shares no state with terminal views, so dragging never remounts a terminal.
struct ManagedWorkflowTabs: View {
    @TerminalTheme private var palette
    let items: [WorkspaceTabItem]
    let selected: String?
    let dragScope: String
    @Binding var showsSwitcher: Bool
    let select: (String) -> Void
    let close: (WorkspaceTabItem) -> Void
    let rename: (CoreWorkflow) -> Void
    let resetName: (CoreWorkflow) -> Void
    let pin: (String) -> Void
    let move: (String, Int) -> Void
    let drop: @MainActor @Sendable (String, String, Bool) -> Void
    let cancel: (UInt64) -> Void
    let create: () -> Void
    let reopen: () -> Void
    let canReopen: Bool
    @State private var dragging: String?
    @State private var insertion: String?
    @State private var insertionAfter = false
    @State private var frames: [String: CGRect] = [:]
    @State private var viewportWidth: CGFloat = 0
    @State private var tabsWidth: CGFloat?
    @State private var scrollEdge = 0

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Text("TABS").sectionLabelStyle().fixedSize().padding(.bottom, 10)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(items) { item in
                            tab(item)
                                .id(item.id)
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
                .scrollIndicators(.hidden)
                .onChange(of: selected) {
                    if let selected { withAnimation(Motion.scrollToSelectedTab) { proxy.scrollTo(selected) } }
                }
                .onChange(of: items.map(\.id)) {
                    if let dragging, !items.contains(where: { $0.id == dragging }) { cancelDrag() }
                    if let selected { proxy.scrollTo(selected) }
                }
                .onGeometryChange(
                    for: CGFloat.self, of: { $0.size.width },
                    action: { _ in
                        if let selected { proxy.scrollTo(selected) }
                    }
                )
                .task(id: scrollEdge) {
                    guard scrollEdge != 0 else { return }
                    var index =
                        items.firstIndex { $0.id == insertion || $0.id == dragging }
                        ?? (scrollEdge < 0 ? items.count : 0)
                    while !Task.isCancelled && scrollEdge != 0 && dragging != nil {
                        index = min(max(index + scrollEdge, 0), max(0, items.count - 1))
                        if items.indices.contains(index) {
                            withAnimation {
                                proxy.scrollTo(items[index].id, anchor: scrollEdge < 0 ? .leading : .trailing)
                            }
                        }
                        try? await Task.sleep(for: .milliseconds(180))
                    }
                }
            }
            .frame(maxWidth: tabsWidth)
            .layoutPriority(1)
            Button("New Workflow", systemImage: "plus", action: create)
                .labelStyle(.iconOnly).buttonStyle(.glass).controlSize(.small)
                .help("New Workflow (⌘T)").accessibilityIdentifier("newWorkflow")
            Spacer(minLength: 0)
            Button {
                showsSwitcher.toggle()
            } label: {
                Label("\(items.count)", systemImage: "chevron.down")
            }
            .buttonStyle(.glass).controlSize(.small).help("Find an Open Tab (⌘⇧A)")
            .fixedSize()
            .accessibilityLabel("Find an open tab, \(items.count) tabs")
            .accessibilityIdentifier("tabSwitcher")
            .popover(isPresented: $showsSwitcher) {
                WorkspaceTabSwitcher(items: items, selected: selected, select: select).appZoom()
            }
        }
        .frame(height: WorkflowTabLayout.height, alignment: .bottom)
        .contextMenu { Button("Reopen Closed Tab", action: reopen).disabled(!canReopen) }
    }

    private func tab(_ item: WorkspaceTabItem) -> some View {
        WorkspaceTab(
            name: item.title, symbol: item.pinned ? "pin.fill" : item.symbol,
            tabID: item.accessibilityID,
            closeID: item.workflow.map { "closeWorkflow-\($0.id)" } ?? "closeFile-\(String(item.id.dropFirst(5)))",
            helpText: [item.title, item.detail, item.status].compactMap { $0 }.joined(separator: "\n"),
            fill: tabFill(item),
            selectedForeground: item.workflow?.showsTerminalStrip == false ? Color(nsColor: palette.text) : nil,
            isEdited: item.isDirty, statusSymbol: item.statusSymbol, statusColor: item.statusColor,
            statusDescription: item.status, unread: item.unread, pinned: item.pinned,
            doubleClick: item.workflow.map { workflow in { rename(workflow) } },
            isSelected: item.id == selected, select: { select(item.id) }, close: { close(item) }
        )
        .contextMenu {
            if let workflow = item.workflow {
                Button("Rename…", systemImage: "pencil") { rename(workflow) }
                Button("Reset Name") { resetName(workflow) }.disabled(workflow.customName == nil)
            }
            Button(item.pinned ? "Unpin Tab" : "Pin Tab", systemImage: item.pinned ? "pin.slash" : "pin") {
                pin(item.id)
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
        }
        .accessibilityAction(named: "Move Left") { move(item.id, -1) }
        .accessibilityAction(named: "Move Right") { move(item.id, 1) }
    }

    private func tabFill(_ item: WorkspaceTabItem) -> Color {
        guard let workflow = item.workflow else { return Color(nsColor: .textBackgroundColor) }
        return workflow.showsTerminalStrip ? .workflowTint : Color(nsColor: palette.background)
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
