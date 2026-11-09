import Observation

/// Temporary tab-list expansion is independent of the native sidebar's docked state.
@Observable
final class SidebarRailHover {
    private(set) var isExpanded = false
    private var isHovered = false
    private var focusedControls: Set<String> = []
    private var menuCount = 0
    private var isDragging = false
    private var isSuppressed = false

    var wantsExpansion: Bool {
        !isSuppressed && (isHovered || !focusedControls.isEmpty || menuCount > 0 || isDragging)
    }

    var isTrackingMenu: Bool { menuCount > 0 }

    func setHovered(_ hovered: Bool) {
        if hovered && !isHovered { isSuppressed = false }
        isHovered = hovered
        collapseIfNeeded()
    }

    func setFocused(_ id: String, _ focused: Bool) {
        if focused {
            if focusedControls.insert(id).inserted { isSuppressed = false }
        } else {
            focusedControls.remove(id)
        }
        collapseIfNeeded()
    }

    func setMenuTracking(_ tracking: Bool) {
        menuCount = max(0, menuCount + (tracking ? 1 : -1))
        collapseIfNeeded()
    }

    func setDragging(_ dragging: Bool) {
        isDragging = dragging
        collapseIfNeeded()
    }

    /// SwiftUI cancels this task when hover/focus leaves or the rail disappears.
    func expandAfterDelay() async {
        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        if !Task.isCancelled, wantsExpansion { isExpanded = true }
    }

    func dismiss() {
        isSuppressed = true
        isExpanded = false
    }

    func reset() {
        isHovered = false
        focusedControls.removeAll()
        menuCount = 0
        isDragging = false
        isSuppressed = false
        isExpanded = false
    }

    private func collapseIfNeeded() {
        if !wantsExpansion { isExpanded = false }
    }
}
