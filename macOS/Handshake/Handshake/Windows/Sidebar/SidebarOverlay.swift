import AppKit
import SwiftUI

/// The minimized sidebar in the sidebar layout: a rail beside the content that widens over it on hover.
/// One container changes width, so the rail and the peek move on a single curve.
struct SidebarOverlay<Rail: View, Peek: View>: View {
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @Environment(\.appZoom) private var zoom
    let presentation: SidebarPresentation
    @ViewBuilder var rail: Rail
    @ViewBuilder var peek: Peek

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: SidebarLayout.overlayCornerRadius) }

    var body: some View {
        let scale = zoom?.scale ?? 1
        let isPeek = presentation.overlay == .peek
        ZStack(alignment: .topLeading) {
            if isPeek {
                peek.frame(width: SidebarLayout.idealWidth * scale).transition(.opacity)
            } else {
                rail.frame(width: SidebarLayout.railWidth * scale).transition(.opacity)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : Motion.sidebarReveal, value: isPeek)
        .frame(width: (isPeek ? SidebarLayout.idealWidth : SidebarLayout.railWidth) * scale, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        // An opaque sidebar surface, so the motion never re-blurs what is behind it.
        .background(Color(nsColor: .windowBackgroundColor), in: shape)
        .clipShape(shape)
        .overlay { shape.strokeBorder(.hairline, lineWidth: Surface.hairlineWidth).allowsHitTesting(false) }
        .shadow(color: .black.opacity(isPeek ? 0.22 : 0.04), radius: isPeek ? 18 : 2, y: isPeek ? 6 : 1)
        // Without Reduce Motion the width animates; with it, the width changes at once and only the fade remains.
        .animation(reduceMotion ? nil : Motion.sidebarReveal, value: isPeek)
        .onHover { inside in
            if inside { presentation.pointerEntered() } else { presentation.pointerExited() }
        }
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in presentation.pressBegan() })
        .task {
            for await _ in NotificationCenter.default.notifications(named: NSMenu.didBeginTrackingNotification) {
                presentation.menuTrackingChanged(isOpen: true)
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: NSMenu.didEndTrackingNotification) {
                presentation.menuTrackingChanged(isOpen: false)
            }
        }
        .onDisappear { presentation.collapse() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(isPeek ? "sidebarPeek" : "sidebarRailContainer")
    }
}
