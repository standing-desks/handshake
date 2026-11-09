import SwiftUI

/// Expands the same tab rows over the workspace, leaving the terminal's layout unchanged.
struct SidebarRail<Content: View>: View {
    @Environment(\.appZoom) private var zoom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let hover: SidebarRailHover
    let maximumWidth: CGFloat
    @ViewBuilder var content: (Bool) -> Content

    var body: some View {
        let scale = zoom?.scale ?? 1
        let width = hover.isExpanded ? SidebarLayout.idealWidth : SidebarLayout.railWidth
        let shape = UnevenRoundedRectangle(
            bottomTrailingRadius: hover.isExpanded ? 8 * scale : 0,
            topTrailingRadius: hover.isExpanded ? 8 * scale : 0)
        content(hover.isExpanded)
            .appZoom()
            .frame(width: min(width * scale, maximumWidth))
            .background(.bar, in: shape)
            .clipShape(shape)
            .overlay(alignment: .trailing) {
                HStack(spacing: 0) { Divider() }
                    .fixedSize(horizontal: true, vertical: false).allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(hover.isExpanded ? 0.16 : 0), radius: 8, x: 3)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: hover.isExpanded)
            .onHover { hover.setHovered($0) }
            .background(SidebarRailEvents(hover: hover))
            .task(id: hover.wantsExpansion) {
                if hover.wantsExpansion { await hover.expandAfterDelay() }
            }
            .onDisappear { hover.reset() }
            .environment(hover)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Tabs")
            .accessibilityValue(hover.isExpanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("sidebarRailContainer")
    }
}

extension View {
    func sidebarRailFocus(_ id: String) -> some View { modifier(SidebarRailFocus(id: id)) }
}

/// Keyboard navigation reveals titles without requesting focus on pointer hover.
private struct SidebarRailFocus: ViewModifier {
    @Environment(SidebarRailHover.self) private var hover
    @FocusState private var isFocused: Bool
    let id: String

    func body(content: Content) -> some View {
        content.focused($isFocused)
            .onChange(of: isFocused) { _, focused in hover.setFocused(id, focused) }
            .onDisappear { hover.setFocused(id, false) }
    }
}
