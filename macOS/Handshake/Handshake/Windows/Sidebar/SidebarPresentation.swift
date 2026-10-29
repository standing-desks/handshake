import AppKit
import Observation

/// The sidebar layout's presentation: whether the minimized sidebar shows its rail or peeks over the
/// content, and which sessions disclose their tabs. Docking stays with the split view's column visibility.
@Observable
final class SidebarPresentation {
    enum Overlay: Equatable {
        /// Icons only, beside the content.
        case rail
        /// The full sidebar over the content, which keeps its size.
        case peek
    }

    private(set) var overlay = Overlay.rail
    /// Sessions whose tabs show beneath them. The selected session joins when it changes.
    var expandedSessions: Set<UInt64> = []
    var isFilesExpanded = true
    var isSessionsExpanded = true
    /// Dialogs the sidebar opens. The window presents them, so closing the peek doesn't dismiss them.
    var sessionToRename: CoreSession?
    var sessionToDelete: CoreSession?
    var tabToRename: WorkspaceTabItem?
    var failure: String?
    @ObservationIgnored private var isPointerInside = false
    @ObservationIgnored private var isMenuOpen = false
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private let peekDelay: Duration
    @ObservationIgnored private let closeDelay: Duration

    init(peekDelay: Duration = SidebarLayout.peekDelay, closeDelay: Duration = SidebarLayout.peekCloseDelay) {
        self.peekDelay = peekDelay
        self.closeDelay = closeDelay
    }

    isolated deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    /// The pointer entered the rail or the peek. Resting on the rail opens the peek after a delay, so a quick
    /// click on a rail icon selects it without expanding.
    func pointerEntered() {
        isPointerInside = true
        guard overlay == .rail else {
            pending?.cancel()
            return
        }
        schedule(after: peekDelay) { $0.show(.peek) }
    }

    func pointerExited() {
        isPointerInside = false
        pending?.cancel()
        if overlay == .peek && !isMenuOpen { schedule(after: closeDelay) { $0.show(.rail) } }
    }

    /// A press on the rail selects an icon; it doesn't also open the peek.
    func pressBegan() {
        if overlay == .rail { pending?.cancel() }
    }

    /// Context menus take the pointer away from the peek without leaving it.
    func menuTrackingChanged(isOpen: Bool) {
        isMenuOpen = isOpen
        if !isOpen && !isPointerInside { pointerExited() }
    }

    /// Returns to the rail at once, for Esc, typing, docking, and leaving the sidebar layout.
    func collapse() {
        pending?.cancel()
        isMenuOpen = false
        show(.rail)
    }

    private func schedule(after delay: Duration, _ action: @escaping (SidebarPresentation) -> Void) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            action(self)
        }
    }

    private func show(_ next: Overlay) {
        guard overlay != next else { return }
        overlay = next
        if next == .peek { installKeyMonitor() } else { removeKeyMonitor() }
    }

    /// The peek never takes the keyboard. Esc or typing goes to the content and closes the peek, except while
    /// a sheet is open or a text field, such as the memory search, is being edited.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.keyPressed(event)
            return event
        }
    }

    private func keyPressed(_ event: NSEvent) {
        guard !event.modifierFlags.contains(.command), event.window?.attachedSheet == nil else { return }
        if let editor = event.window?.firstResponder as? NSTextView, editor.isFieldEditor { return }
        collapse()
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
