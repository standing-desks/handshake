# 0019: Retain terminal presentations and cache parsed history

Status: Accepted

Selecting a terminal must reuse its emulator, output consumer, trace positions,
and viewport. Reconstructing ANSI history during activation makes selection cost
proportional to transcript length. SwiftTerm already renders the visible rows;
hiding its view until replay completes leaves the expensive work on the UI path.

Retain each native terminal presentation for its core terminal ID within its
folder window. A SwiftUI attachment owns a host view, while the presentation owns
the terminal and controller. Core terminal closure evicts the presentation.
Visibility never invalidates trace indexing or changes the user's scroll position.

Keep live AppKit state on the main actor. Confine historical emulators and trace
indexes to background actors, transferring immutable interpreted rows and sparse
trace positions. Historical device queries have no route to a live process.
Install bounded history pages directly into SwiftTerm's ring buffer, preserving
the live screen, cursor, parser, selection, modes, and viewport. Resize and clear
boundaries reject stale results. Keep the pinned SwiftTerm API and Metal renderer;
the focused integration extends ADR 0014 without adopting a different engine.

Core owns a disposable cache of parsed display pages, carried over the binary
bridge separately from raw terminal bytes and structured traces. Cache I/O uses
its own bounded worker so it cannot block canonical recording or PTY delivery.
Publish a page directory after writing its changed pages. Apply per-terminal and
global storage bounds, and remove cache ownership when transcripts are pruned.
Missing, incompatible, corrupt, or incomplete cache pages fall back to background
reconstruction from the canonical transcript. The raw transcript format remains
unchanged.

On relaunch a new process owns a fresh terminal invocation and accepts input
while earlier invocations load. Restore the most recent parsed page first, then
continue loading older pages automatically. Saved display rows are historical
content; they never restore an old process's protocol state into its replacement.
An invocation ending in an alternate screen contributes its final visible screen
to the read-only display. Traces load through their existing independent core APIs.

Carrying parsed rows requires a versioned derived format and a small maintained
SwiftTerm integration. This avoids transferring mutable terminal objects between
actors or replaying historical protocol bytes through the live view. Existing
recordings require one background conversion before their parsed cache exists.
