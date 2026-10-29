import SwiftUI

struct SessionRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(TabLayout.storageKey) private var tabLayout = TabLayout.defaultValue
    let session: CoreSession
    let isSelected: Bool
    var monogram = ""
    /// In the sidebar layout, a session discloses its tabs and summarizes them while collapsed.
    var isExpanded: Binding<Bool>?
    var tabCount = 0
    var activity: WorkspaceTabItem.Activity?
    var isDropTarget = false
    let select: () -> Void
    let rename: () -> Void
    let delete: () -> Void
    var newWorkflow: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            if let isExpanded { disclosure(isExpanded) }
            Button(action: select) {
                HStack(spacing: 4) {
                    if isExpanded == nil { Color.clear.frame(width: 11) }
                    SessionMonogram(letters: monogram, isActive: isSelected)
                        .frame(width: 16)
                    Text(session.name).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, isExpanded == nil ? SidebarLayout.rowInset : 0)
                .frame(height: SidebarLayout.rowHeight).contentShape(.rect)
            }
            .buttonStyle(.plain).help(session.name)
            .accessibilityLabel(session.name)
            .accessibilityIdentifier("sessionRow-\(session.id)")
            .accessibilityValue(accessibilityValue)
            ZStack(alignment: .trailing) {
                if isExpanded?.wrappedValue == false {
                    summary.opacity(isHovered ? 0 : 1).accessibilityHidden(true)
                }
                hoverActions.opacity(isHovered ? 1 : 0).allowsHitTesting(isHovered).accessibilityHidden(!isHovered)
            }
        }
        .font(.system(size: SidebarLayout.rowFontSize, weight: isSelected ? .medium : .regular))
        .padding(.trailing, SidebarLayout.rowInset)
        .frame(height: SidebarLayout.rowHeight).contentShape(.rect)
        .background(
            isSelected && isExpanded == nil ? Color.fileSelection : .clear,
            in: .rect(cornerRadius: CornerRadius.fileRowSelection)
        )
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: CornerRadius.fileRowSelection).strokeBorder(.tint, lineWidth: 2)
                    .background(Color.fileSelection, in: .rect(cornerRadius: CornerRadius.fileRowSelection))
                    .allowsHitTesting(false)
            }
        }
        .onHover { isHovered = $0 }
        .contextMenu { actions }
    }

    private var accessibilityValue: String {
        var parts = [isSelected ? "Selected" : nil]
        if let isExpanded {
            parts.append(tabCount == 1 ? "1 tab" : "\(tabCount) tabs")
            parts.append(isExpanded.wrappedValue ? "Expanded" : "Collapsed")
            if !isExpanded.wrappedValue { parts.append(activity?.description) }
        }
        return parts.compactMap { $0 }.joined(separator: ", ")
    }

    private func disclosure(_ isExpanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : Motion.sectionToggle) { isExpanded.wrappedValue.toggle() }
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 11, height: SidebarLayout.rowHeight)
                .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.leading, SidebarLayout.rowInset)
        .accessibilityLabel(isExpanded.wrappedValue ? "Collapse \(session.name)" : "Expand \(session.name)")
        .accessibilityIdentifier("sessionDisclosure-\(session.id)")
    }

    private var summary: some View {
        HStack(spacing: 5) {
            Text("\(tabCount)").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            if let activity { TabActivityGlyph(activity: activity) }
        }
    }

    private var hoverActions: some View {
        HStack(spacing: 0) {
            if let newWorkflow {
                Button("New Workflow in \(session.name)", systemImage: "plus", action: newWorkflow)
                    .labelStyle(.iconOnly).buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: SidebarLayout.rowHeight).contentShape(.rect)
                    .help("New Workflow in “\(session.name)”")
                    .accessibilityIdentifier("sessionNewWorkflow-\(session.id)")
            }
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: SidebarLayout.rowHeight)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .frame(width: 22, height: SidebarLayout.rowHeight)
            .accessibilityLabel("Actions for \(session.name)").accessibilityIdentifier("sessionActions-\(session.id)")
        }
    }

    @ViewBuilder private var actions: some View {
        if let newWorkflow {
            Button("New Workflow", systemImage: "plus", action: newWorkflow)
            Divider()
        }
        Button("Rename Session", systemImage: "pencil", action: rename)
        Button("Delete Session", systemImage: "trash", role: .destructive, action: delete)
        Divider()
        Button(
            tabLayout.toggleTitle,
            systemImage: tabLayout == .sidebar ? "rectangle.topthird.inset.filled" : "sidebar.left"
        ) { tabLayout = tabLayout.toggled }
    }
}
