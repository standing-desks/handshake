# Automatic Twine Memories trial

This branch now runs an automatic, local AMIS 0.4 memory reconciler for Codex and
Claude Code. The interactive memory journey is
[journey-of-a-memory.html](journey-of-a-memory.html); the architecture walkthrough is
[native-memory-visual-guide.html](native-memory-visual-guide.html).

Twine owns the canonical AMIS library at
`~/Library/Application Support/Twine/memories`. It captures eligible native project
memories, appends immutable observations and consolidated views, and delivers them
in native harness formats. Fresh Twine sessions receive their native memory
configuration automatically. There is no shared-catalog retrieval instruction and
no import button in the primary UI.

## Try the small workspace

Use `~/workspaces/twine-memory-small/Open in Twine.command`. The new trial app is
**Twine AMIS Memory**, bundle identifier `com.twineproject.Twine.amis-memory-trial`.
Its application state is isolated at `~/workspaces/.twine-amis-memory-trial-state`;
its memory store deliberately uses the standard Twine location above. The old
1,001-topic playground, both obsolete state stores and the earlier trial app were
removed. All 1,019 injected files in its native Claude memory directory were deleted,
and its native Codex thread was excluded from future memory generation. Unrelated
projects and ordinary chat history were preserved.

Open **Twine** beside **Memories** to see the project policy, status and current
memories. Sharing is enabled automatically. **Sync now** is optional. Start a fresh
Codex or Claude session and ask an ordinary project question.

Codex builds its generated startup memory in its own background pass. Native file
delivery can precede that pass, and native quota or memory settings can defer it.
Existing Codex sessions created in the global home retain that home on resume;
start a fresh session to use the managed project home. Existing conversations can
retain earlier startup context.

## Native integration

- **Claude:** an invocation-only `--settings` value selects `autoMemoryDirectory`
  at `~/.claude/projects/twine-<project UUID>/memory/`. It merges with Twine's existing
  observer hooks. User authentication, configuration and session-history locations
  stay in their normal locations. The native `MEMORY.md` links to Twine's native
  project index and topic files.
- **Codex:** a per-project `CODEX_HOME` lives under
  `memories/projects/<project UUID>/native/codex`. Credentials, configuration and
  supported user guidance are reused; memory and session state remain project
  scoped. Inputs go to `memories/extensions/ad_hoc/notes/`. Codex owns its generated
  `MEMORY.md`, `memory_summary.md`, extraction stores and consolidation scheduling.
- **Capture:** native Claude topics, Codex ad-hoc notes and managed native Codex
  registry entries. Entries from the global Codex registry require an exact native
  cwd binding. Arbitrary chat transcripts and unrelated project memories are not
  automatically shared.
- **Feedback:** owned unchanged files are recognized by local publication state.
  Generated Codex registry snapshots retain known delivered ancestry and are
  exported to Claude without being fed into Codex's own input notes again.

Native session leases prevent background replacement while that harness is
running. Delivery into the other idle harness continues. The worker retries after
the active session ends; an existing conversation's startup context is not hot
replaced. Standalone CLI sessions use their ordinary profile unless launched
through Twine.

## AMIS and durable storage

Schemas are vendored unchanged from AMIS commit
`9723ef4f33a3aadb194f8c6db14291102ddc182a`; see
[UPSTREAM.md](../../twine-core/contracts/amis-0.4.0/UPSTREAM.md).

Each project keeps `library.amis.json`, local receiver bindings, exact source
snapshots, native before/after blobs, sealed publication plans, local policy
transactions and byte-verification receipts. AMIS metadata cannot grant local
write authorization. Unknown receiver identities, bad integrity, duplicate JSON
keys, conflicting heads, unsupported time bounds and unsafe native paths hold
reconciliation rather than overwriting memory.

Consolidation is deterministic: exact text can share a derived view, with separate
source identities retained. Similar or contradictory claims stay separate. Twine
makes no model calls for this pass. Native memory generation uses the harness's
normal quota controls; this machine's Codex threshold remains 10%.

Source disappearance does not erase history. Explicit withdrawal appends a
withdrawal revision and corrects owned native copies, including original managed
source notes. Generated native summaries can retain an old claim until their
harness refreshes them; receipts claim native-byte availability, not guaranteed
forgetting or recall.

## Validation

- Full library/app format, lint, build and unit checks are recorded in
  `out/validation/memory-journey/check-final.log`. One unrelated model-listing
  process fixture missed its 300 ms startup window during a repeated run; the
  complete rerun passed. The failed-run log is retained as
  `out/validation/memory-journey/check-process-fixture-failure.log`.
- Focused tests cover bidirectional capture, native updates, duplicate prevention,
  malformed documents, project isolation, receiver-binding recovery, crash windows,
  independent index edits, per-harness leases and grouped withdrawal retry.
- The pinned AMIS reference checker validates actual generated bundles, plans,
  capabilities and receipts through the C ABI. Evidence:
  `out/validation/twine-amis/ffi-validation.json`.
- Four real macOS UI tests pass: automatic two-way sharing with a native edit,
  native byte verification and relaunch; pause/reopen/resume; active-session
  deferral with automatic retry; and readable storage details with reachable actions
  at 200% zoom. Evidence: `out/validation/memory-journey/fixture-ux-final.log`.
- Two small seeded native facts were recalled through ordinary questions in fresh
  agents launched from the actual Twine menus. Codex answered `maple-417` from the
  Claude-origin memory; Claude answered `green` from the Codex-origin memory.
  Neither prompt nor workspace contained the values. Screenshots and recorded
  responses were checked. Evidence: `out/validation/memory-journey/ux-validation.json`.
- Screenshot review caught an earlier case mislabeled as Claude that actually
  launched Codex. That case was excluded; selection is now scoped and persisted
  harness identity is checked before sending. A Claude first-run trust dialog also
  consumed one attempted input; no model question was delivered in that attempt.
  The corrected Claude-only run passed in 37.620 seconds. In total this renewed
  test sent two Codex questions and one Claude question. Codex's rounded weekly
  meter remained at 88%; Claude usage was not measured.
- UX fixes: normal native lease deferral no longer shows a red Sync now failure;
  the storage disclosure uses a plain accessible button that works at 200% zoom.
- The actual small trial's AMIS library, 11 sealed plans/capability documents and
  11 receipts pass the pinned reference validator. Evidence:
  `out/validation/memory-journey/amis-validation.json`.
- The old workspace and injected native memories were removed with zero model
  calls. Evidence: `out/validation/memory-journey/cleanup.json`.
- The new journey guide passes 144 WebKit states at 375, 768 and 1160 px, including
  both directions, active-session and revision states, plus navigation. Evidence:
  `out/validation/memory-journey/html-validation.json`.
- Fresh native Codex consolidated and recalled the Claude-origin fictional account
  code. Weekly usage was 88% before and after the tiny run. Evidence:
  `out/validation/twine-amis/native-e2e.json` (Codex results).
- Fresh native Claude recalled the Codex-origin fictional deployment lane and
  performed two reads from its native memory directory. Evidence:
  `out/validation/twine-amis/claude-recall-fixed.json`.
- The HTML walkthrough passes 36 WebKit states at 375, 768 and 1440 px, plus its
  navigation controls. Evidence: `out/validation/native-memory-visual/validation.json`.

These are local trial results. Schema/reference checks do not constitute independent
AMIS synchronizer certification or broad compatibility across future harness versions.

The older explicit native importer remains in core for compatibility; the primary
app flow now uses the automatic Twine AMIS memory implementation.
