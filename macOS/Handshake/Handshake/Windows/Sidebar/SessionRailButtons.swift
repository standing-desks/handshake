import SwiftUI

/// A session in the minimized rail: its monogram, marked with its tabs' most urgent activity while collapsed.
struct RailSessionButton: View {
    let session: CoreSession
    let letters: String
    let isSelected: Bool
    let activity: WorkspaceTabItem.Activity?
    let isDropTarget: Bool
    let showsTitles: Bool
    let isExpanded: Bool
    let select: () -> Void
    let toggleExpanded: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: 4) {
                    Text(letters)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .frame(width: 20, height: 20)
                        .background(.quaternary, in: .rect(cornerRadius: 5))
                        .overlay(alignment: .topTrailing) {
                            if let activity { RailActivityBadge(activity: activity) }
                        }
                        .frame(width: 40)
                    if showsTitles {
                        Text(session.name).font(.system(size: SidebarLayout.rowFontSize, weight: .medium))
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).frame(height: SidebarLayout.rowHeight)
                .contentShape(.rect)
            }
            .buttonStyle(.plain).help(session.name).sidebarRailFocus("session-\(session.id)")
            .accessibilityLabel(session.name)
            .accessibilityValue(
                [isSelected ? "Selected" : nil, activity?.description].compactMap { $0 }.joined(separator: ", ")
            )
            .accessibilityIdentifier("railSession-\(session.id)")
            if showsTitles { disclosure }
        }
        .background(isDropTarget ? Color.fileSelection : .clear, in: .rect(cornerRadius: CornerRadius.fileRowSelection))
    }

    private var disclosure: some View {
        Button(action: toggleExpanded) {
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary).rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 28, height: SidebarLayout.rowHeight).contentShape(.rect)
        }
        .buttonStyle(.plain).sidebarRailFocus("session-disclosure-\(session.id)")
        .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") \(session.name)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}

/// Compact tab navigation uses one selection fill and keeps activity visible beside the icon.
struct RailTabButton: View {
    let item: WorkspaceTabItem
    let focusID: String
    let sessionName: String
    let isSelected: Bool
    let insertion: VerticalEdge?
    let showsTitles: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: 4) {
                    icon.frame(width: 40)
                    if showsTitles {
                        Text(item.title).font(.system(size: SidebarLayout.rowFontSize))
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).frame(height: SidebarLayout.tabRowHeight)
                .contentShape(.rect)
            }
            .buttonStyle(.plain).help(item.title).sidebarRailFocus(focusID)
            .accessibilityLabel(item.title).accessibilityHint(sessionName)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityValue(accessibilityValue)
            .accessibilityIdentifier("rail-\(item.accessibilityID)")
            if showsTitles { closeButton }
        }
        .background(isSelected ? Color.fileSelection : .clear, in: .rect(cornerRadius: CornerRadius.fileRowSelection))
        .overlay(alignment: insertion == .top ? .top : .bottom) {
            if insertion != nil { Rectangle().fill(.tint).frame(height: 2) }
        }
    }

    private var icon: some View {
        Image(systemName: item.pinned ? "pin.fill" : item.symbol)
            .font(.system(size: 16)).foregroundStyle(isSelected ? Color.primary : .secondary)
            .frame(width: 18, height: 18)
            .overlay(alignment: .topTrailing) {
                if let activity = item.activity { RailActivityBadge(activity: activity) }
            }
            .overlay(alignment: .bottomTrailing) {
                if item.isDirty { Circle().fill(.primary).frame(width: 4, height: 4).offset(x: 4, y: 2) }
            }
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 28, height: SidebarLayout.tabRowHeight).contentShape(.rect)
        }
        .buttonStyle(.plain).sidebarRailFocus("close-\(focusID)")
        .accessibilityLabel("Close \(item.title)").accessibilityIdentifier("rail-\(item.closeID)")
    }

    private var accessibilityValue: String {
        [
            isSelected ? "Selected" : nil, item.isDirty ? "Edited" : nil, item.pinned ? "Pinned" : nil,
            item.activity?.description,
        ].compactMap { $0 }.joined(separator: ", ")
    }
}

/// Shapes distinguish activity even when color differences are difficult to see.
struct RailActivityBadge: View {
    let activity: WorkspaceTabItem.Activity

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(TabActivityGlyph(activity: activity).dotColor)
            .background(.background, in: .circle)
            .offset(x: 5, y: -3)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch activity {
        case .running: "ellipsis.circle.fill"
        case .done: "checkmark.circle.fill"
        case .needsAttention: "exclamationmark.circle.fill"
        }
    }
}
