# ADR 0016: Sessions own their file and browser tabs

- Status: Accepted
- Date: 2026-10-29
- Partially supersedes: [ADR 0002](0002-graduate-tab-management.md), for the scope of file and browser tabs

## Context

File editors and browser pages belonged to the folder window, so every session's
tab bar showed the same files and pages. A sidebar that lists every session
([ADR 0015](0015-show-tabs-in-the-sidebar-by-default.md)) has to show each tab under
one session, and a session is the body of work those files and pages are open for.

## Decision

Each session holds its own file and browser tabs, in both layouts. This remains
Swift presentation state: each session's arrangement in `WorkspaceTabsModel` lists
the pages it holds, next to its existing order, pins, and selection. Core keeps no
page state.

- Opening a file from the Files section or a memory, or opening a browser tab,
  puts it in the selected session.
- A page an agent opens through browser control
  ([ADR 0012](0012-control-the-embedded-browser-through-core.md)) joins the session
  of the agent's terminal. Core includes that terminal with each browser job. When
  an agent brings its page to the front while another session is selected, the page
  stays with its own session.
- A file can be open in several sessions. Their tabs share one editor and buffer,
  so unsaved edits can't diverge. Closing it in one session removes only that tab;
  the editor closes, and asks about unsaved changes, when no session holds it.
- Switching sessions restores that session's own selection, including a file or
  page. Pages of other sessions stay loaded in the background.
- Reopen Closed Tab brings a file or page back to the session it closed from.
- Deleting a session closes the pages only it holds, after confirming unsaved
  files first so that a cancel leaves the session and its tabs intact.
- A page that no existing session holds joins the selected session. This places
  tabs that were open before this change and recovers any a deleted session left.
  References to pages that are no longer open are pruned.

Saved arrangements from earlier versions still decode, with no pages. Earlier
versions ignore the new field.

## Consequences

In the top layout, a session's tab bar no longer shows other sessions' files and
pages. Moving a file or page to another session stays in Swift; a file moved to a
session that already holds it merges into that tab. ADR 0002's other decisions
still hold: one standard tab experience, saved names, order, pins, and selection,
and tab arrangement kept in Swift.

## References

- [Presentation state](../../macOS/Handshake/Handshake/Workflows/Workspace/WorkspaceTabsModel.swift)
- [Tab preparation](../../macOS/Handshake/Handshake/Workflows/Workspace/WorkspaceTabBar.swift)
- [Closing tabs](../../macOS/Handshake/Handshake/Workflows/Workspace/WorkspaceTabClosing.swift)
- [Session dialogs](../../macOS/Handshake/Handshake/Windows/Sidebar/SidebarDialogs.swift)
- [Agent browser pages](../../macOS/Handshake/Handshake/Browser/BrowserControlHost.swift)
