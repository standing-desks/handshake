# ADR 0015: Show tabs in the sidebar by default

- Status: Accepted
- Date: 2026-10-29
- Amended: 2026-11-09, compact tab rail presentation
- Partially supersedes: [ADR 0006](0006-align-and-quiet-the-folder-top-bar.md), for the sidebar layout only

## Context

The tab bar shows only the selected session's tabs, so work running in other
sessions is invisible until the user switches to them. A sidebar that lists every
session can show each session's tabs and their status at once, and frees the 32-point
tab row for the terminal panel.

## Decision

Add an app-wide presentation preference, `tabLayout`, with two values: `sidebar`
(the default) and `top`. Store it with the app's other presentation preferences
in `UserDefaults`, not in core configuration or the Experimental catalog. People
switch layouts from the context menus of tabs, sessions, and the tab bar
(Show Tabs at the Top / Show Tabs in the Sidebar) and from the View menu. People
upgrading from the tab bar get the sidebar layout, with a one-time hint in the
toolbar subtitle.

Sessions use a letter monogram in both layouts. In the sidebar layout:

- The Sessions section comes before Files and Memories. Each session discloses its
  tabs as rows: its workflows (one row per terminal split), files, and browser
  pages. Rows show the kind symbol or pin, activity (running, done, or needs
  attention), pane count, and the edited dot. A collapsed session shows its tab
  count and most urgent activity.
- There is no tab bar. The terminal panel takes its height and draws its full
  hairline. Split Right, Split Down, New Workflow, New Browser Tab, and Find Open Tab
  move into the window toolbar, immediately before Keep Awake, which keeps its
  ADR 0011 placement. On macOS 26.1 and later the split group overflows first and
  the tab group stays with Keep Awake. The toolbar subtitle shows the selected
  session and tab, within the bounded title width from ADR 0011.
- Find Open Tab searches every session's tabs and switches session on selection.
- The docked sidebar remains the `NavigationSplitView` column, keeping its native
  toggle, resizing, and ⌃⌘S. A folder that hasn't chosen opens it docked. When it
  is hidden, a 52-point rail of monograms and tab icons stays beside the content.
  It uses system sidebar material, a trailing divider, and 32-point rows. The
  selected tab has one rounded selection fill; quieter session monograms mark
  groups, and distinct activity symbols remain visible while collapsed.
- Hovering or focusing the rail temporarily expands the same rows into a labeled
  tab list over the workspace. Icons and rows keep their positions, and the terminal
  keeps its dimensions. A short dwell avoids expansion when the pointer passes
  across the rail. The list stays open during keyboard navigation, dragging, and
  native menu interaction. Leaving collapses it; Escape dismisses it until a new
  hover or focus entry. The sidebar button deliberately docks the full sidebar.
  The window continues to own sidebar dialogs. Both presentations retain the
  outline's scroll anchor and minimally reveal the current selection.

The November 2026 amendment keeps vertical tabs available as persistent compact
navigation. Safari's vertical-tab presentation is a visual reference for its
integrated surface and quiet selection. Chrome and Firefox inform its temporary
hover expansion into a labeled tab list. It replaces the original floating rail
card and timed expansion into the entire sidebar.

The top layout keeps the ADR 0006 tab row, with Move to Session and the layout
switch added to its menus. The `workflowTint` fill behind the agent subtab strip,
the selected agents tab, the agent surface, and Bento gutters is removed in both
layouts.

## Consequences

The change stays in Swift presentation code except for moving workflows between
sessions ([ADR 0017](0017-move-workflows-between-sessions.md)). Existing UI tests
seed the `top` layout so they keep covering the tab bar, and separate UI tests cover
the sidebar layout.

Docking uses the native split-view animation. Compact and expanded navigation share
row identifiers and presentation state. The collapsed native column releases its
focusable outline, leaving one active tab list. Tabs can move within or between
sessions through the outline's existing drag behavior and the Move to Session menu.

## References

- [Tab layout preference](../../macOS/Handshake/Handshake/Workflows/Workspace/TabLayout.swift)
- [Folder window composition](../../macOS/Handshake/Handshake/Windows/FolderView.swift)
- [Session outline](../../macOS/Handshake/Handshake/Windows/Sidebar/SessionOutline.swift)
- [Sidebar presentation](../../macOS/Handshake/Handshake/Windows/Sidebar/SidebarPresentation.swift)
- [Rail hover state](../../macOS/Handshake/Handshake/Windows/Sidebar/SidebarRailHover.swift)
- [Rail presentation](../../macOS/Handshake/Handshake/Windows/Sidebar/SidebarRail.swift)
- [Toolbar buttons](../../macOS/Handshake/Handshake/Workflows/Workspace/WorkspaceToolbar.swift)
- [Apple sidebar guidance](https://developer.apple.com/design/human-interface-guidelines/sidebars)
- [Safari vertical-tab presentation](https://sixcolors.com/post/2026/11/safari-update-brings-vertical-tabs-adaptive-dark-mode-ai-integration/)
- [Chrome vertical-tab hover expansion](https://support.google.com/chrome/answer/2391819?co=GENIE.Platform%3DDesktop&hl=en)
- [Firefox hover interaction tests](https://github.com/mozilla-firefox/firefox/blob/main/browser/components/sidebar/tests/browser/browser_sidebar_expand_on_hover.js)
