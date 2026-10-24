# Native cross-agent memory trial

This branch imports this folder’s Claude Code memories into Codex’s native memory
system. Memory bodies live in native harness directories. Twine has no active
shared catalog, shared inbox or external memory-body database, and it injects no
shared-memory retrieval instructions at agent launch.

The implemented direction is **Claude Code → Codex native import**. This is not a
continuous bidirectional synchronizer. AMIS serialization and conformance are not
part of this implementation.

## Try the playground

Use `~/workspaces/cross-agent-memory-playground` in the development build. Its
`Open in Twine.command` launcher restores the dedicated playground app state.
The rebuilt native playground window is already open with the Native Memory
interface. Its dedicated state is `~/workspaces/.twine-native-memory-playground-state`,
which has no `shared-memory` directory. The launcher now reopens that state.

1. Click the branching-arrow beside **Memories** to open **Native Memory**.
2. Check the Claude and Codex native paths and source-file count.
3. Click **Import Claude Memories**. This is an explicit call to Codex’s own
   importer, restricted to this folder’s memory item.
4. Inspect the result. A request accepted by Codex is distinct from confirmed
   import completion; native consolidation and recall are later steps.
5. Run a normal Codex session so its background memory consolidation can proceed.
   Test an ordinary question in a fresh session afterward.

CLI fallback for the installed Codex 0.164 build:

```sh
cd /Users/megatron/workspaces/cross-agent-memory-playground
codex --enable external_agent_memory_import
```

In that idle local session, type `/import`, choose Claude Code, and select only
this project’s memories. Leave configuration,
instructions, skills, plugins, other projects and chat sessions unselected.
See [OpenAI’s import guide](https://learn.chatgpt.com/docs/import).

## Native storage

Claude’s playground directory:

```text
~/.claude/projects/-Users-megatron-workspaces-cross-agent-memory-playground/memory/
  MEMORY.md
  <category indexes>.md
  <native topic files>.md
```

The current installed Codex importer owns its copies under:

```text
~/.codex/memories/extensions/external_agent_import/resources/
  -Users-megatron-workspaces-cross-agent-memory-playground/
```

Codex owns consolidation from those imported resources. Twine does not modify
its generated `MEMORY.md`, summary files or SQLite state to simulate ingestion.
Claude’s native index is loaded at startup and topic files are read as needed;
see [Claude’s memory documentation](https://code.claude.com/docs/en/memory).
The playground `AGENTS.md` and `CLAUDE.md` contain only project scope and evaluation
boundaries. Neither prescribes memory retrieval nor points at the former store.

## Implementation

`twine-core/src/memories/native_import.rs` owns folder validation, native location
discovery, feature gating, import selection and completion interpretation. The
Swift–Rust bridge passes requests and responses; Swift’s `Memories/` subsystem
renders native paths and import states through `CoreClient`.

The installed Codex 0.164 build gates memory migration separately behind
`external_agent_memory_import`. Twine starts only the importer child with
`codex --enable external_agent_memory_import app-server`; no persisted settings
change. An ordinary existing CLI session may omit memory import without this
flag. This native feature opt-in adds no memory-retrieval startup instructions.

Status inspection reads Codex’s effective configuration, then uses
`externalAgentConfig/detect`. Import submits only a `MEMORY` item for this exact
Claude project key through `externalAgentConfig/import`. Other migration types
are not forwarded. Scope checks reject a mismatched native directory or missing
project association. The code uses the installed Codex memory migration schema;
an unavailable or incompatible native API is an error, not a fallback to another
memory store.

Codex’s documented [app-server API](https://learn.chatgpt.com/docs/app-server)
provides detection, selected import and completion notifications. Twine matches
`externalAgentConfig/import/completed` to the returned import ID and verifies
success for the selected source. An accepted request with missing completion is
reported as unconfirmed. A completed file import still does not establish native
consolidation or model recall.

The previous launch-only shared-memory instructions and exchange directory access
are removed. Normal workflow role instructions remain independent of memory.
No process is started merely to fabricate a memory conversation.

## Verified playground evidence

- [Migration report](../../../../cross-agent-memory-playground/native-migration-report.json):
  1,001 source records, including one later user note, migrated with original bodies
  preserved and source hashes verified. Claude has 1,019 native Markdown files:
  1,001 topics, 17 category indexes and a 33-line, 1,582-byte `MEMORY.md`.
- [Native recall report](../../../../cross-agent-memory-playground/native-recall-report.json):
  a fresh Claude CLI session answered “Which customer and account key should I use
  for a demo?” correctly in 6.31 seconds and read a native topic. There were no
  appended Twine memory instructions, extra directory grants, available external
  catalog or permission denials.
- [Native Codex detection](../../../../cross-agent-memory-playground/native-codex-detection.json):
  the importer child with the native feature enabled detected exactly one memory
  item for this playground. The compiled bridge returned `ready`,
  `canImport=true`, and 1,019 native files. Saved settings were unchanged; no
  import was executed.
- Codex native import remains pending the user’s action. Native Codex consolidation
  and recall have not been verified. The full 20-question native suite is unscored.
- `make fmt` and full `make check` passed: 577 Rust tests (45 bridge + 532 core;
  11 existing ignores), plus 372 Swift tests across 483 executions.
- The debug build and code-signature verification passed. Both Rust and Swift
  reviews cleared. Logs: [full check](../../out/validation/native-memory/check.log)
  and [debug build](../../out/validation/native-memory/build.log).
- The native playground was registered and opened using fresh app state with no
  shared-memory directory. See the [folder receipt](../../../../cross-agent-memory-playground/native-folder-receipt.json).

Native importer tests exercise memory-only selection, folder scope, read-only
status, completion matching and unavailable native configuration. No live native
import-button click test or completed Codex import is claimed; actual import and
native Codex recall remain separate pending steps.

## Historical evidence and limits

The former external shared library is explicitly disabled. Old memory bodies
remain in `~/workspaces/.twine-memory-playground-state` as historical state.
The new native window uses separate app state with no shared-memory directory.
Legacy reports and bodies are not used for current native delivery.
The old publication report and catalog-based model tests do not establish native
loading or recall. Do not rerun the retired loader to validate this architecture.

A native import is a snapshot. Later source edits need another native import;
there is no automatic Codex-to-Claude reverse path. Removal from one native store
does not erase earlier imported copies or already-loaded conversations. Each
harness owns its memory lifecycle and context-loading behavior.

The trial adds no fixed note-count or topic-size quota. Native harness limits and
protocol transport bounds still apply. Memory content remains local until its
owning harness reads and sends it to the selected model provider.
