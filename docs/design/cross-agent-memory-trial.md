# Cross-agent memory trial

This branch adds a usable, experimental shared library for Codex and Claude Code.
It builds on Twine v0.3.3 (`efb0daf`) and uses the existing native launch-instruction
channels. It does not modify either harness's personal memory store or repository
instruction files.

## Try it

After the first build, double-click `Open Cross-Agent Memory.command` in this
checkout. The launcher uses a separate preferences suite and opens a new instance.

Build and open the development app from this checkout:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make debug
./"Open Cross-Agent Memory.command"
```

1. Open the folder you want the two harnesses to work in.
2. Click the branching-arrow button beside **Memories** in the sidebar.
3. Enable **Automatically share memories in this folder**.
4. Add a harmless test note, for example: `# Trial convention` followed by
   `The example release checklist is called the cedar checklist.`
5. Start a new Codex agent in that folder. Ask it to find the shared release
   checklist convention and cite the note it read.
6. Ask Codex to retain another harmless folder-specific procedure in the shared
   inbox. Inspect the note in Shared Memory after the next refresh.
7. Start Claude Code in the same folder and ask about that procedure. Inspect
   its actual tool reads and answer; receiving a catalog does not prove recall.

Reverse the harness order to test the other direction. New agents get the
discovery instructions and access to the same folder-specific exchange directory.
Existing agents need a fresh launch after enabling the feature; later notes can
be read by already-configured agents when they re-read the catalog.

To seed from existing memory, select a folder-owned Codex/Claude durable memory
in Memories, open Shared Memory, and choose **Import selected memory snapshot**.
Instructions, transcripts, global memories and unbound configured Claude stores
are not eligible. This is a one-time snapshot, not native-store synchronization.

## What runs automatically

The folder's presentation requests a background core refresh every five seconds,
even with the sidebar hidden. A new supported harness launch also refreshes the
library. The core accepts new UTF-8 `.md` inbox files only when the local
folder policy is enabled. Agents are told to stage a temporary file and rename it
after writing, and to create new files rather than edit accepted ones.

SQLite stores accepted content, source labels, hashes, policy, held/withdrawn
status and exact-content suppression. A generated catalog points to immutable
content snapshots. The catalog and records are rebuildable views of committed
state. Refresh responses contain note metadata; the app fetches a selected body
on demand and can filter titles and sources. Native launch options preserve the user's existing Codex instructions and
append shared-memory discovery beside workflow role instructions.

Changes to an accepted inbox filename are held; they do not silently replace the
original note. Withdraw the old note and add a qualified replacement. Identical
copies of withdrawn content are also suppressed. This is exact-byte replay
protection, not detection of semantic paraphrases. Missing inbox files are not
treated as withdrawal.

## Storage and controls

The library lives under the app's data directory:

```text
shared-memory/<hash of canonical folder path>/
  ledger.sqlite3
  exchange/
    catalog.md
    inbox/        # agents contribute new files here
    records/      # core-generated snapshots
```

Development state is isolated to this checkout's `out/runtime/debug`, unless
`TWINE_DATA_DIRECTORY` is explicitly provided. The policy is local, outside the
repository; another repository cannot enable it by shipping a configuration file.
Different folder paths, including worktrees, get separate libraries. A renamed
folder does not automatically inherit the former folder's binding.

Disable sharing to stop new intake and delivery; enabling again admits pending
inbox files under the same policy. Withdrawal removes the note from the generated
view and retains history and suppression. It is not payload erasure. Already-read
agent contexts and previous copies cannot be revoked by deleting a local file.

Notes are stored on this Mac, but either harness may send selected content to its
model provider. This trial has no extra model service or semantic summarizer.
Use nonsecret folder-specific knowledge. The native clients receive directory
access to the exchange area; all processes still run as the same local user.
This is an application policy, not a security sandbox between hostile agents.

## Current limits

- The original 128-note and 16 KiB inbox-note ceilings have been removed. The complete
  inbox is scanned, including entries beyond the former scan cutoff. Storage and
  refresh work still grow with the library; this is not a claim of infinite capacity.
- Generic IPC request limits and the existing native source reader's bounds still
  apply to manual Add/import operations. File-based inbox intake has no fixed shared-note quota.
- A file-based catalog and exact content snapshots; no semantic retrieval service.
- No automatic semantic consolidation, contradiction resolution, transcript capture,
  AMIS exchange/export, or claim of AMIS publisher conformance.
- No native global-store synchronization. Snapshot imports preserve their source
  location but are not updated when the native original changes.
- No automatic proof of model use. Test the handoff in both harnesses and inspect
  their actual reads. The app does not run a paid model merely to check a write.
- Background intake requires the folder to remain open in Twine. Launch refresh
  still catches up before a newly started supported harness receives context.

These constraints keep the first trial focused on the shared-library and bounded
discovery path from the MemCurrent-informed proposal. AMIS revision/derivation
interchange and reviewed model consolidation remain separate follow-up work.

## How sharing works today

Both harnesses read one Twine-managed library: Markdown inbox contributions become
accepted SQLite records, then the core publishes a catalog and exact Markdown
snapshots. Harness launch instructions grant access and point to that catalog.
Agents search or inspect its metadata and read the relevant full files. Startup
instructions do not contain the entire library or a fixed eight-topic preview.

This route does not normalize to AMIS or convert back into native memory stores.
A selected native import is a one-time text snapshot. A future AMIS canonical
record layer could preserve portable identities, revisions, lineage and scope
while using this same read path. Native adapters would be optional and would
need to describe any semantic loss; copying every native store is not required.

## Validation

Use `make fmt` and `make check` from the repository root. Shared-memory coverage
includes the real Swift-to-Rust bridge, opt-in policy, isolation between folders,
new-note intake, changed-note holds, duplicate withdrawal, replay suppression,
projection failure recovery, descriptor-relative path access, and both harness
instruction mappings. These checks do not independently demonstrate model recall.

Current local results (24 October 2026): `make fmt` and `make check` passed.
Rust: 45 bridge tests and 523 core tests passed; 11 existing core tests ignored.
Swift: 368 tests passed (479 executions including parameterized cases).
The focused native UI smoke test and debug app build passed. Both required
reviewers found no remaining blocking issues. Logs and the current UI screenshot
are in `out/validation/cross-agent-memory-scale/`.

The live playground preserves its original four notes and admits 996 additions:
1,000 shared memories, with all new records verified byte-for-byte and a largest
record of 256 KiB. Local subprocess/core/JSON measurements were 7.78 s for initial
admission/publication, 89.1 ms median over three steady refreshes, and 19.5 ms to
read the largest note. These timings exclude Swift rendering and model inference.
No live model recall score is claimed. The playground includes 20 recall prompts
and an operator answer key outside the project and exchange directories.

Schema v2 migrates existing notes and suppression unchanged and persists the last
publication result. Detail reads use a deferred database transaction and do not
scan the inbox or republish records. They still examine stored bodies to derive
metadata titles; refresh work still grows with the library.
