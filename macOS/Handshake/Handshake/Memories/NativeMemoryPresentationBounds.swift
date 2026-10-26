import AppKit
import SwiftUI

/// Keep the zoomed sheet inside its parent window's horizontal bounds.
struct NativeMemoryPresentationBounds: NSViewRepresentable {
    let update: (CGFloat) -> Void

    func makeNSView(context: Context) -> BoundsView { BoundsView(update: update) }
    func updateNSView(_ view: BoundsView, context: Context) { view.update = update }

    final class BoundsView: NSView {
        var update: (CGFloat) -> Void
        private var updateTask: Task<Void, Never>?

        init(update: @escaping (CGFloat) -> Void) {
            self.update = update
            super.init(frame: .zero)
            for name in [
                NSWindow.willBeginSheetNotification, NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification,
            ] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(boundsChanged), name: name, object: nil)
            }
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            publishBounds()
        }

        @objc private func boundsChanged(_ notification: Notification) {
            guard let changed = notification.object as? NSWindow,
                changed === window || changed === window?.sheetParent
            else { return }
            publishBounds()
        }

        private func publishBounds() {
            updateTask?.cancel()
            updateTask = Task { [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self, let parent = window?.sheetParent else { return }
                update(parent.contentLayoutRect.width)
            }
        }

        isolated deinit {
            updateTask?.cancel()
            NotificationCenter.default.removeObserver(self)
        }
    }
}
