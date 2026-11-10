import Testing

@testable import Handshake

@MainActor
struct SidebarRailHoverTests {
    @Test func leavingDuringDwellDoesNotExpand() async {
        let hover = SidebarRailHover()
        hover.setHovered(true)
        let pending = Task { await hover.expandAfterDelay() }
        hover.setHovered(false)
        pending.cancel()
        await pending.value
        #expect(!hover.isExpanded)
        #expect(!hover.wantsExpansion)
    }

    @Test func escapeStaysCollapsedUntilThePointerReenters() async {
        let hover = SidebarRailHover()
        hover.setHovered(true)
        await hover.expandAfterDelay()
        #expect(hover.isExpanded)
        hover.dismiss()
        await hover.expandAfterDelay()
        #expect(!hover.isExpanded)
        hover.setHovered(false)
        hover.setHovered(true)
        await hover.expandAfterDelay()
        #expect(hover.isExpanded)
    }

    @Test func nestedMenusKeepTheListOpenUntilTrackingEnds() async {
        let hover = SidebarRailHover()
        hover.setHovered(true)
        await hover.expandAfterDelay()
        hover.setMenuTracking(true)
        hover.setMenuTracking(true)
        hover.setHovered(false)
        hover.setMenuTracking(false)
        #expect(hover.isExpanded)
        hover.setMenuTracking(false)
        #expect(!hover.isExpanded)
    }

    @Test func keyboardFocusAndDraggingKeepTheListAvailable() async {
        let hover = SidebarRailHover()
        hover.setFocused("tab-1-file:shared.swift", true)
        await hover.expandAfterDelay()
        #expect(hover.isExpanded)
        hover.setFocused("tab-2-file:shared.swift", true)
        hover.setFocused("tab-1-file:shared.swift", false)
        #expect(hover.isExpanded)
        hover.setDragging(true)
        hover.setFocused("tab-2-file:shared.swift", false)
        #expect(hover.isExpanded)
        hover.setDragging(false)
        #expect(!hover.isExpanded)
    }
}
