import AppKit
import SwiftUI

/// A visible popover must receive Escape even when its scroll view or selectable text has focus.
struct MemorySharingPopoverDismissal: NSViewRepresentable {
    let ownerWindowNumber: Int?
    let dismiss: () -> Void

    func makeNSView(context: Context) -> DismissalView {
        DismissalView(ownerWindowNumber: ownerWindowNumber, dismiss: dismiss)
    }
    func updateNSView(_ view: DismissalView, context: Context) {
        view.ownerWindowNumber = ownerWindowNumber
        view.dismiss = dismiss
    }

    final class DismissalView: NSView {
        var dismiss: () -> Void
        var ownerWindowNumber: Int?
        private var keyboardMonitor: Any?

        init(ownerWindowNumber: Int?, dismiss: @escaping () -> Void) {
            self.ownerWindowNumber = ownerWindowNumber
            self.dismiss = dismiss
            super.init(frame: .zero)
            setAccessibilityElement(false)
            keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let popover = window, popover.isVisible,
                    event.keyCode == 53,
                    event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
                    let target = event.window ?? NSApp.keyWindow,
                    target === popover || target.windowNumber == self.ownerWindowNumber,
                    target.attachedSheet == nil, target.sheetParent == nil,
                    NSApp.modalWindow == nil || NSApp.modalWindow === popover
                else { return event }
                self.dismiss()
                return nil
            }
        }

        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        isolated deinit {
            if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        }
    }
}
