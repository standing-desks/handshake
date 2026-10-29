# ADR 0015: Show tabs in the sidebar by default

- Status: Accepted
- Date: 2026-10-29
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

In the sidebar layout:

- The Sessions section comes first. Each session discloses its tabs as rows: its
  workflows (one row per terminal split), files, and browser pages. Rows show the
  kind symbol or pin, activity (running, done, or needs attention), pane count,
  and the edited dot. A collapsed session shows its tab count and most urgent
  activity. Sessions use a letter monogram in both layouts.
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
  Resting on the rail for 250 ms widens it into a peek over the content, which
  closes 300 ms after the pointer leaves. The peek never takes keyboard focus; Esc
  or typing closes it, except while a text field is being edited or a sheet is
  open. The sidebar's sheets and alerts belong to the window so they outlive the
  peek. The sidebar button is the only dock control. Reduce Motion turns the rail
  and peek into a fade.

The top layout keeps the ADR 0006 tab row, with Move to Session and the layout
switch added to its menus. The `workflowTint` fill behind the agent subtab strip,
the selected agents tab, the agent surface, and Bento gutters is removed in both
layouts.

## Consequences

The change stays in Swift presentation code except for moving workflows between
sessions ([ADR 0017](0017-move-workflows-between-sessions.md)). Existing UI tests
seed the `top` layout so they keep covering the tab bar; the sidebar layout needs
its own UI coverage.

The implementation differs from the design proposal in four places, each of which
would need a single sidebar view instead of the split view column plus an overlay:
docking uses the system sidebar animation rather than one continuous morph from
the rail; the rail and the peek cross-fade rather than sharing rows; dragging over
the rail doesn't open the peek; and tabs can't be dragged from the top tab bar onto
a session, which the Move to Session menu covers.

## References

- [Tab layout preference](../../macOS/Handshake/Handshake/Workflows/Workspace/TabLayout.swift)
- [Folder window composition](../../macOS/Handshake/Handshake/Windows/FolderView.swift)
- [Session outline](../../macOS/Handshake/Handshake/Windows/Sidebar/SessionOutline.swift)
- [Rail and peek](../../macOS/Handshake/Handshake/Windows/Sidebar/SidebarPresentation.swift)
- [Toolbar buttons](../../macOS/Handshake/Handshake/Workflows/Workspace/WorkspaceToolbar.swift)
