# ADR 0017: Move workflows between sessions in core

- Status: Accepted
- Date: 2026-10-29

## Context

People reorganize work by moving tabs between sessions. The session a workflow
belongs to is domain state that core persists, so a move can't be presentation
state alone.

## Decision

Add `Command::MoveWorkflow { workflow_id, session_id }` to `handshake-core`. The
bridge decodes `moveWorkflow` with `workflowId` and `sessionId`. The command rejects
a workflow that isn't open (`workflowNotFound`), a session that isn't loaded
(`sessionNotFound`), and a session outside the open folder (`folderChanged`).
Moving to the workflow's current session is accepted and changes nothing.
Otherwise core persists the new session, updates its state, and emits
`WorkflowChanged`. Terminals, runs, traces, and transcripts are keyed by workflow
or terminal, so running work continues untouched. Archived workflows can move.

The app sends the command for every pane of a terminal split, so a split moves as
one tab. If a pane fails to move, the panes that already moved go back before the
error is reported. Tab position and pins stay in Swift presentation state, and a
moved tab arrives unpinned. A selected tab stays selected, making its new session
current. Moving between sessions is registered with the window's undo manager,
except when a file merges into a tab the destination already holds.

## Consequences

Deleting either session afterwards behaves as for any other workflow: the moved
workflow belongs to its new session. Like other commands, a move made in one
window isn't reflected in another window open on the same folder.

## References

- [Command handling](../../handshake-core/src/application/tabs.rs)
- [Workflow store](../../handshake-core/src/store/workflows.rs)
- [Bridge decoding](../../handshake-bridge/src/protocol/workflows.rs)
- [Moving tabs](../../macOS/Handshake/Handshake/Workflows/Workspace/WorkspaceTabNavigation.swift)
