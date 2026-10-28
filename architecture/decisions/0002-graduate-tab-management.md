# ADR 0002: Graduate tab management from the feature-flag catalog

- Status: Accepted
- Date: 2026-10-27
- Related issue: [HAND-81](https://linear.app/standing-desks/issue/HAND-81)

## Context

The enhanced tab experience currently requires the Tab management feature flag.
It provides rename, reorder, pin, search, reopen, keyboard navigation, and shared
workflow, file, and browser tab presentation. The requested behavior makes this
experience standard for every folder.

## Decision

Remove Tab management from the feature-flag catalog and Settings. Use the enhanced
tab experience unconditionally instead of retaining an optional path whose
default happens to be enabled.

Preserve saved tab names, order, pins, selection, and file/browser presentation.
Existing configuration files containing the retired `tab_management` setting
remain readable; that setting no longer disables the standard tab experience.
Do not rewrite unrelated settings while handling the retired option.

Keep tab arrangement and selection in Swift presentation state. Workflow behavior
and durable workflow names continue to belong to `handshake-core` and use the
existing `CoreClient` boundary.

Once a window begins preserving its presentation for shutdown, session changes
from core teardown must not rerun tab restoration or replace saved snapshots.

## Consequences

Users receive one consistent tab experience. The implementation removes obsolete
feature branches, catalog entries, and tests that only exercise the retired gate,
while retaining behavioral coverage for tab operations and configuration
compatibility. Disabling the feature is no longer a user option.

## References

- [Current feature catalog](../../handshake-core/src/config/features.rs)
- [Tab composition](../../macOS/Handshake/Handshake/Workflows/Workspace/WorkspaceTabBar.swift)
- [Presentation state](../../macOS/Handshake/Handshake/Workflows/Workspace/WorkspaceTabsModel.swift)
- [Workflow presentation](../../macOS/Handshake/Handshake/Workflows/Workspace/WorkflowWorkspace.swift)
