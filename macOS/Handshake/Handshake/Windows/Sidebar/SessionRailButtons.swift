import SwiftUI

/// A session in the minimized rail: its monogram, marked with its tabs' most urgent activity while collapsed.
struct RailSessionButton: View {
    let session: CoreSession
    let letters: String
    let isSelected: Bool
    let activity: WorkspaceTabItem.Activity?
    let isDropTarget: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            SessionMonogram(letters: letters, isActive: isSelected)
                .overlay(alignment: .topTrailing) {
                    if let activity { RailActivityDot(activity: activity) }
                }
                .frame(maxWidth: .infinity).frame(height: SidebarLayout.rowHeight).contentShape(.rect)
                .background(
                    isDropTarget ? Color.fileSelection : .clear, in: .rect(cornerRadius: CornerRadius.fileRowSelection))
        }
        .buttonStyle(.plain)
        .help(session.name)
        .accessibilityLabel(session.name)
        .accessibilityValue(
            [isSelected ? "Selected" : nil, activity?.description].compactMap { $0 }.joined(separator: ", ")
        )
        .accessibilityIdentifier("railSession-\(session.id)")
    }
}

/// A tab in the minimized rail: its symbol, ringed when selected.
struct RailTabButton: View {
    let item: WorkspaceTabItem
    let isSelected: Bool
    let insertion: VerticalEdge?
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            Image(systemName: item.pinned ? "pin.fill" : item.symbol)
                .font(.system(size: 12)).foregroundStyle(isSelected ? Color.primary : .secondary)
                .overlay(alignment: .topTrailing) {
                    if let activity = item.activity { RailActivityDot(activity: activity) }
                }
                .frame(maxWidth: .infinity).frame(height: SidebarLayout.tabRowHeight).contentShape(.rect)
                .background(
                    isSelected ? Color.fileSelection : .clear, in: .rect(cornerRadius: CornerRadius.fileRowSelection)
                )
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: CornerRadius.fileRowSelection).strokeBorder(
                            .tint, lineWidth: 1.5)
                    }
                }
                .overlay(alignment: insertion == .top ? .top : .bottom) {
                    if insertion != nil { Rectangle().fill(.tint).frame(height: 2) }
                }
        }
        .buttonStyle(.plain)
        .help([item.title, item.activity?.description].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityLabel(item.title)
        .accessibilityValue(
            [isSelected ? "Selected" : nil, item.activity?.description].compactMap { $0 }.joined(separator: ", ")
        )
        .accessibilityIdentifier("rail-\(item.accessibilityID)")
    }
}

/// The rail's small activity dot, cut out from the icon it marks.
struct RailActivityDot: View {
    let activity: WorkspaceTabItem.Activity

    var body: some View {
        Circle().fill(TabActivityGlyph(activity: activity).dotColor)
            .frame(width: 6, height: 6)
            .overlay { Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1) }
            .offset(x: 4, y: -3)
            .accessibilityHidden(true)
    }
}
