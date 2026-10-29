import AppKit
import SwiftUI

/// One tab under its session in the sidebar layout: a workflow, a file, or a browser page.
struct SessionTabRow<Actions: View>: View {
    let item: WorkspaceTabItem
    let isSelected: Bool
    /// Panes in the tab's terminal split; one for every other tab.
    var paneCount = 1
    var insertion: VerticalEdge?
    let select: () -> Void
    let rename: (() -> Void)?
    let close: () -> Void
    @ViewBuilder var actions: Actions
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: activate) {
                HStack(spacing: 6) {
                    Image(systemName: item.pinned ? "pin.fill" : item.symbol)
                        .frame(width: 16).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(item.title).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: SidebarLayout.tabRowHeight).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.title)
            .accessibilityValue(
                [
                    isSelected ? "Selected" : nil, item.isDirty ? "Edited" : nil, item.pinned ? "Pinned" : nil,
                    item.activity?.description, paneCount > 1 ? "\(paneCount) panes" : nil,
                ]
                .compactMap { $0 }.joined(separator: ", ")
            )
            .accessibilityIdentifier(item.accessibilityID)
            ZStack(alignment: .trailing) {
                status.opacity(isHovered ? 0 : 1).accessibilityHidden(true)
                Button("Close \(item.title)", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly).buttonStyle(.plain)
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 18).contentShape(.rect)
                    .opacity(isHovered ? 1 : 0).allowsHitTesting(isHovered).accessibilityHidden(!isHovered)
                    .accessibilityIdentifier(item.closeID)
            }
        }
        .font(.system(size: SidebarLayout.rowFontSize, weight: isSelected ? .medium : .regular))
        .padding(.leading, SidebarLayout.tabRowIndent)
        .padding(.trailing, SidebarLayout.rowInset)
        .frame(height: SidebarLayout.tabRowHeight)
        .contentShape(.rect)
        .background(isSelected ? Color.fileSelection : .clear, in: .rect(cornerRadius: CornerRadius.fileRowSelection))
        .overlay(alignment: insertion == .top ? .top : .bottom) {
            if insertion != nil {
                Rectangle().fill(.tint).frame(height: 2).padding(.leading, SidebarLayout.tabRowIndent - 6)
                    .accessibilityHidden(true)
            }
        }
        .onHover { isHovered = $0 }
        .contextMenu { actions }
        .help([item.title, item.detail, item.activity?.description].compactMap { $0 }.joined(separator: "\n"))
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 5) {
            if paneCount > 1 {
                Label("\(paneCount)", systemImage: "rectangle.split.2x1")
                    .labelStyle(.titleAndIcon).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            if item.isDirty { Circle().fill(.secondary).frame(width: 5, height: 5) }
            if let activity = item.activity { TabActivityGlyph(activity: activity) }
        }
    }

    private func activate() {
        if let event = NSApp.currentEvent, event.type == .leftMouseUp, event.clickCount == 2, let rename {
            rename()
        } else {
            select()
        }
    }
}

/// A workflow's activity on its sidebar row and its session's collapsed summary.
struct TabActivityGlyph: View {
    let activity: WorkspaceTabItem.Activity

    var body: some View {
        switch activity {
        case .running:
            WorkingDot()
        case .done:
            Image(systemName: "checkmark.circle").font(.system(size: 10)).foregroundStyle(Color.statusRunning)
        case .needsAttention:
            Image(systemName: "exclamationmark.circle").font(.system(size: 10))
                .foregroundStyle(Color.statusNeedsAttention)
        }
    }

    /// The color of the rail's small dot.
    var dotColor: Color {
        switch activity {
        case .running: .statusRunning
        case .done: .statusComplete
        case .needsAttention: .statusNeedsAttention
        }
    }
}
