import AppKit
import SwiftUI

struct WorkspaceTab: View {
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    let name: String
    let symbol: String
    let tabID: String
    let closeID: String
    let helpText: String
    let fill: Color
    var selectedForeground: Color?
    var isEdited = false
    var statusSymbol: String?
    var statusColor: Color = .secondary
    var statusDescription: String?
    var pinned = false
    var doubleClick: (() -> Void)?
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var isHovered = false
    @FocusState private var focusedControl: Control?

    private enum Control: Hashable { case select, close }

    private var showsClose: Bool { isHovered || focusedControl != nil }

    var body: some View {
        Button(action: activate) {
            titleContent
        }
        .buttonStyle(.plain)
        .focused($focusedControl, equals: .select)
        .accessibilityLabel(name)
        .accessibilityValue(
            [
                isSelected ? "Selected" : nil, isEdited ? "Edited" : nil, pinned ? "Pinned" : nil,
                statusDescription,
            ].compactMap { $0 }.joined(separator: ", ")
        )
        .accessibilityIdentifier(tabID)
        .background {
            if isSelected {
                tabShape.fill(fill)
                    .overlay {
                        tabShape.strokeBorder(.hairline, lineWidth: Surface.hairlineWidth)
                            .mask { Rectangle().padding(.bottom, Surface.hairlineWidth) }
                    }
            }
        }
        .overlay(alignment: .leading) {
            Button("Close \(name)", systemImage: "xmark", action: close)
                .labelStyle(.iconOnly)
                .foregroundStyle(isSelected ? selectedForeground ?? .primary : .primary)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 20, height: 23)
                .buttonStyle(.plain)
                .focused($focusedControl, equals: .close)
                .padding(.leading, 9)
                .opacity(showsClose ? 1 : 0)
                .allowsHitTesting(showsClose)
                .accessibilityHidden(!showsClose)
                .accessibilityIdentifier(closeID)
        }
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : Motion.tabCloseButton, value: showsClose)
        .help(helpText)
    }

    private func activate() {
        if let event = NSApp.currentEvent, event.type == .leftMouseUp, event.clickCount == 2, let doubleClick {
            doubleClick()
        } else {
            select()
        }
    }

    private var titleContent: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .frame(width: 15)
                .opacity(showsClose ? 0 : 1)
            Text(name)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 180)
            if let statusSymbol {
                Image(systemName: statusSymbol).font(.system(size: 9)).foregroundStyle(statusColor)
            }
            if isEdited {
                Circle().fill(.secondary).frame(width: 5, height: 5).accessibilityHidden(true)
            }
        }
        .tabTitleStyle(isSelected: isSelected, foreground: isSelected ? selectedForeground : .primary)
        .padding(.horizontal, 12)
        .frame(height: WorkflowTabLayout.height)
        .contentShape(.rect)
    }

    private var tabShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: CornerRadius.selectedTab, topTrailingRadius: CornerRadius.selectedTab)
    }
}
