# ADR 0006: Align and quiet the folder top bar

- Status: Accepted
- Date: 2026-10-28
- Partially supersedes: [ADR 0001](0001-preserve-native-controls-and-add-accessible-motion.md), tab-row glass styling only

## Context

The folder top bar mixes glass creation buttons, flat tabs, a shorter tab-count
menu, and independently offset split controls. Inactive tabs also use a shorter
height than selected tabs. These differences make related controls look uneven,
especially at larger interface zoom levels.

## Decision

Keep the two-row layout and existing control order. The native sidebar control,
folder name, and path stay in the title bar; Keep Awake stays at its trailing
edge. New Workflow and New Browser Tab stay immediately after the tabs. The tab
switcher and terminal split controls stay at the trailing edge of the tab row.

Use the existing 32-point base tab height for selected and inactive tabs, creation
buttons, the tab switcher, and split-control hit areas. Center their labels and
symbols vertically and let the existing app zoom scale the row together.
Reveal the selected tab again when the native scroll content or viewport width
changes, so insertion animations, zoom, and title changes cannot leave it clipped.
Make this geometry correction nonanimated, and exclude scroll offset from its
trigger so users can still scroll the row manually.
When revealing the last tab, explicitly align its trailing edge with the viewport.

Use native bordered buttons with a shared rounded-rectangle shape for creation
and tab switching, replacing the glass style specified in ADR 0001. Keep split
controls borderless and preserve the selected tab's connection to its content.
Use matching caption typography for the tab-row actions and stronger inactive
tab text. Preserve the existing shortcuts, focus behavior, tooltips, and labels.

Keep Awake retains its native toolbar capsule, cup-and-saucer symbol, label,
and explicit On/Off value. Soften the foreground when off and retain the system
accent tint when on. Let the toolbar own its material and overflow behavior;
replacing its shared background can remove the capsule in some appearances.

## Consequences

The change stays in Swift presentation code and does not alter workflows,
terminal lifetimes, saved state, or app-wide sleep prevention. Native controls
continue to own their interaction states and adapt to system appearance. The
HTML preview is directional; native rendering is the implementation reference.

Verify alignment in light and dark appearances at multiple zoom levels and with
Always-visible scrollbars. Exercise tab creation, switching, overflow, browser
tabs, terminal splits, and Keep Awake, including its toolbar overflow behavior.

## References

- [Tab-row controls](../../macOS/Handshake/Handshake/Workflows/Workspace/WorkspaceBarControl.swift)
- [Tab composition](../../macOS/Handshake/Handshake/Workflows/Workspace/ManagedWorkflowTabs.swift)
- [Keep Awake](../../macOS/Handshake/Handshake/Windows/KeepAwakeControl.swift)
- [Native geometry checks](../../macOS/Handshake/HandshakeUITests/Workflows/TabManagementEdgeCasesUITests.swift)
