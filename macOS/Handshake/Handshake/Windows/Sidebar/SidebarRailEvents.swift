import AppKit
import SwiftUI

/// Native menus and terminal keyboard events don't travel through SwiftUI's hover/focus handlers.
struct SidebarRailEvents: NSViewRepresentable {
    let hover: SidebarRailHover

    func makeNSView(context: Context) -> SidebarRailEventView { SidebarRailEventView(hover: hover) }
    func updateNSView(_ nsView: SidebarRailEventView, context: Context) {}
    static func dismantleNSView(_ nsView: SidebarRailEventView, coordinator: ()) { nsView.stop() }
}

final class SidebarRailEventView: NSView {
    private let hover: SidebarRailHover
    private var keyboardMonitor: Any?
    private var trackingMenus: Set<ObjectIdentifier> = []

    init(hover: SidebarRailHover) {
        self.hover = hover
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard let window else { return }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(menuBegan), name: NSMenu.didBeginTrackingNotification, object: nil)
        center.addObserver(self, selector: #selector(menuEnded), name: NSMenu.didEndTrackingNotification, object: nil)
        center.addObserver(
            self, selector: #selector(windowResigned), name: NSWindow.didResignKeyNotification, object: window)
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, event.keyCode == 53,
                self.hover.isExpanded, !self.hover.isTrackingMenu
            else { return event }
            self.hover.dismiss()
            return nil
        }
    }

    func stop() {
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        keyboardMonitor = nil
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSMenu.didBeginTrackingNotification, object: nil)
        center.removeObserver(self, name: NSMenu.didEndTrackingNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        for _ in trackingMenus { hover.setMenuTracking(false) }
        trackingMenus.removeAll()
    }

    @objc private func menuBegan(_ notification: Notification) {
        guard window?.isKeyWindow == true, hover.isExpanded, let menu = notification.object as? NSMenu else { return }
        if trackingMenus.insert(ObjectIdentifier(menu)).inserted { hover.setMenuTracking(true) }
    }

    @objc private func menuEnded(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu,
            trackingMenus.remove(ObjectIdentifier(menu)) != nil
        else { return }
        hover.setMenuTracking(false)
    }

    @objc private func windowResigned() { hover.dismiss() }

    isolated deinit { stop() }
}
