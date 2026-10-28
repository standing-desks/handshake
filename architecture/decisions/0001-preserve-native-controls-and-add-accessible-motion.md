# ADR 0001: Preserve native controls and add accessible layout motion

- Status: Accepted
- Date: 2026-10-27
- Related issue: [HAND-81](https://linear.app/standing-desks/issue/HAND-81)

## Context

Some presentation changes, including terminal splits and tab creation, happen
without transitions. Other surfaces already use shared motion values. HAND-81
requests consistent motion without redesigning the interface, delaying terminal
I/O, or ignoring the system Reduce Motion setting.

The existing toolbar and tab strip are established interactions. Keep Awake is
an app-wide native toolbar button, while workflow and browser creation controls
belong beside the tab strip. These controls must remain recognizable and reachable.

## Decision

Preserve the current controls, their placement, labels, and actions:

- Keep Awake remains at the trailing side of the native window toolbar. Its
  cup-and-saucer symbol, Keep Awake label, and On/Off value remain visible.
- New Workflow follows the visible tab strip, with New Browser Tab immediately
  after it. Empty space separates these creation controls from the trailing tab
  switcher. The terminal split controls remain at the trailing edge.
- Settings remains accessible through the app's Settings command. This change
  does not introduce a settings button in the folder-window toolbar.
- Tabs/Bento selection stays in the agent workflow's existing layout controls.

Give New Workflow and New Browser Tab the shared tab-strip height, including at
different app zoom levels. Use native SwiftUI glass buttons with flexible sizing
and explicit shared dimensions rather than relying on OS-dependent intrinsic
control heights or drawing replacement controls.

Add motion in Swift presentation code using shared values. Use approximately
180 ms for tab insertion/removal and 220 ms for pane layout
changes. Retain existing expansion and workflow-choice motion where it already
fits the interaction. Apply Reduce Motion consistently, using instant or minimal
transitions when enabled.

Keep terminal identity stable across layout changes. Animate presentation frames
without recreating terminal emulators, restarting processes, or delaying input
and output. Selection and divider dragging respond directly to the user. Respect
the current focus and accessibility behavior throughout a transition.

Group each agent pane's geometry so the pane frame interpolates as a unit while
its header appears or disappears. Keep the layout and terminal identities stable;
no separate animation state is needed.

Forward Reduce Motion through native hosting boundaries so nested terminal
presentation follows the same accessibility policy as the folder window. Use a
writable effective-motion environment value that falls back to SwiftUI's read-only
system setting. An optional override supports isolated Debug UI tests; it does
not change the user's system preferences or add a persisted product setting.

## Consequences

The implementation needs an inventory of affected surfaces and validation of
terminal identity, keyboard focus, overflow reachability, and Reduce Motion.
Animation work belongs in Swift; it does not move presentation state into core.
HTML prototypes illustrate the interaction, while native rendering remains the
reference for control appearance and placement.

Native UI coverage includes control alignment in both appearances at multiple
zoom levels, overflow reachability, split behavior in both motion modes, and
agent terminal identity while switching Tabs/Bento layout.

## References

- [Keep Awake control](../../macOS/Handshake/Handshake/Windows/KeepAwakeControl.swift)
- [Folder-window toolbar](../../macOS/Handshake/Handshake/Windows/FolderView.swift)
- [Managed tab strip](../../macOS/Handshake/Handshake/Workflows/Workspace/ManagedWorkflowTabs.swift)
- [Tab placement checks](../../macOS/Handshake/HandshakeUITests/Workflows/TabManagementEdgeCasesUITests.swift)
- [Shared motion values](../../macOS/Handshake/Handshake/Design/Design.swift)
