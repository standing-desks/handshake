# ADR 0009: Inventory Handshake rename surfaces and compatibility contracts

- Recorded: 2026-10-24
- Status: Accepted
- Provenance: Approved rebrand scope and HAND-82 inventory requirements.
- Issue: [HAND-82: Inventory Twine names and inputs](https://linear.app/standing-desks/issue/HAND-82/inventory-twine-names-and-inputs)

## Context

The rename spans Rust, the C ABI, Swift, launch environments, saved data, build
scripts, release artifacts, and public links. Independent substitutions can break
producer/consumer contracts or strand user settings. This inventory assigns each
surface one implementation owner and records which old names remain readable.

## Decision

Use Handshake for the product and the target component names in CONTEXT.md.
Retain the domain vocabulary and architecture. Follow CONTRIBUTING.md for identity
and compatibility policy. This record describes planned work; it does not claim
that the migrations below have been implemented.

An owner owns a **name**, across every producer, consumer, test, fixture, comment,
and current documentation example, regardless of which issue normally owns the
file. Other issues leave that name alone. Source paths in this snapshot are lookup
coordinates, not requests to keep the old directory names. Use the renamed path
when implementing after a directory move.

Priority is: exact variable/constant row, exact cross-boundary surface row, then
surface family. A file can contain several independently owned surfaces; the
source index is evidence, not whole-file ownership. Historical changelog entries,
released downloads, user content, and historical ADR provenance remain unchanged.
This ADR itself records old names intentionally and remains historical evidence.
The temporary designer reference is untouched, exempt from the leftover-name
audit, and removed only by HAND-131; no lasting document depends on it.

### Owners

| Issue | Responsibility |
| --- | --- |
| HAND-84 | Rust crate directories, manifests, imports, and library identity |
| HAND-88 | C ABI symbols/header, Swift packages and framework identity |
| HAND-89 | Core saved-data migration and storage compatibility |
| HAND-99 | Bridge/app wiring of core migration and production data-root selection |
| HAND-90 | Config root, imports, user workflows, themes, and config override |
| HAND-105 | Presentation continuity, launch overrides, and preference domains |
| HAND-91 | Shell helpers, OSC protocol, launchers, and shell integration tests |
| HAND-92 | Harness identification, observers, placeholders, completion, harness overrides |
| HAND-95 | Xcode project, source directories, targets, and internal Swift names |
| HAND-98 | Component instructions and instruction paths after directory renames |
| HAND-101 | Build/test/site automation, filters, caches, tooling, and general test fixtures |
| HAND-108 | Release artifacts, signing, notarization, installer layout, and plist build key |
| HAND-110 | Release version, changelog addition, and tap notification event |
| HAND-106 | Visible application branding, diagnostics, permission/accessibility strings |
| HAND-107 | Current contributor/product/migration documentation and update links |
| HAND-94 | Website product copy, metadata, downloads, and current site URLs |
| HAND-86 | Legacy website redirects and anchors |
| HAND-116 | Remote product repository rename |
| HAND-117 | Remote metadata and integration verification |
| HAND-96 | Primary Homebrew tap cask and migration mappings |
| HAND-97 | Compatibility Homebrew tap cask and migration mappings |
| HAND-104 | In-app logo replacement |
| HAND-133 | Xcode app-icon wiring and old icon removal |
| HAND-93 | Installer artwork and previews |
| HAND-109 | Product screenshot and its alt text |
| HAND-83 | Product vocabulary and root/reviewer instructions |
| HAND-114 | Final tracked-name audit against this inventory |
| HAND-131 | Removal of the temporary design reference |

### Environment variables and uppercase tokens

**User-facing override**: introduce the corresponding `HANDSHAKE_` input; retain
`TWINE_` as fallback, and give the new input precedence when both are supplied.
Preserve each input's existing validation and empty-value semantics. In particular,
a rejected new config path must not silently select a legacy path instead.

**Internal protocol marker or placeholder**: rename outright, with no fallback.
**Test/CI-only**: rename outright, including test fixture state and sentinels.
For both, mechanically replace `TWINE` with `HANDSHAKE`, retaining surrounding
underscores. The Xcode `TEST_RUNNER_` transport prefix stays; its suffix follows
the underlying variable's owner and policy. Every listed wrapper and base input
must change together.

C/Rust constants are listed separately from environment inputs to avoid creating
meaningless environment fallbacks for status codes or embedded theme sources.
They rename outright with the same numeric values/behavior. Evidence includes all
tracked textual occurrences at the baseline, even historical documentation that
must be preserved. A concatenation of the path start and end markers is two
markers, not a third variable (`__TWINE_PATH____TWINE_END__`).

| Name | Classification | Owner | Producer/consumer evidence |
| --- | --- | --- | --- |
| `TEST_RUNNER_TWINE_DATA_DIRECTORY` | User-facing override | HAND-105 | `Makefile:169` |
| `TEST_RUNNER_TWINE_PREFERENCES_SUITE` | User-facing override | HAND-105 | `Makefile:33` |
| `TEST_RUNNER_TWINE_TEST_GIT` | Test/CI-only | HAND-101 | `Makefile:179` |
| `TWINE_AGENT` | Test/CI-only | HAND-101 | `macOS/Twine/TwineUITests/Support/UITestSupport.swift:124`<br>`macOS/Twine/TwineUITests/Terminal/TerminalHistoryUITests.swift:92`<br>`macOS/Twine/TwineUITests/Workflows/AgentSubtabsUITests.swift:39`<br>`macOS/Twine/TwineUITests/Workflows/BentoUITests.swift:180,215` |
| `TWINE_BENCH_COMPLETION_WITNESS` | Test/CI-only | HAND-92 | `macOS/Twine/TwineUITests/Workflows/LocalPiWorkflowUITests.swift:66` |
| `TWINE_BENCH_RUN_ID` | Test/CI-only | HAND-92 | `macOS/Twine/TwineUITests/Workflows/LocalPiWorkflowUITests.swift:65` |
| `TWINE_BRIDGE_H` | Code constant (rename outright) | HAND-88 | `twine-bridge/include/twine_bridge.h:1,2` |
| `TWINE_COMPLETION` | Internal protocol marker or placeholder | HAND-92 | `twine-core/src/workflow_run.rs:799`<br>`twine-core/src/workflow_run/graph.rs:625` |
| `TWINE_CONFIG_PATH` | User-facing override | HAND-90 | `CHANGELOG.md:198`<br>`macOS/Twine/Twine/TwineApp.swift:29,30`<br>`macOS/Twine/TwineUITests/Files/HTMLPreviewUITests.swift:17`<br>`twine-core/src/config.rs:192,198` |
| `TWINE_CRASH_TEST_DATA` | Test/CI-only | HAND-89 | `twine-core/src/application/recovery.rs:340,383` |
| `TWINE_CRASH_TEST_MODE` | Test/CI-only | HAND-89 | `twine-core/src/application/recovery.rs:344,384` |
| `TWINE_DARK` | Code constant (rename outright) | HAND-90 | `twine-core/src/config/themes.rs:16,233,277,680` |
| `TWINE_DATA_DIRECTORY` | User-facing override | HAND-105 | `macOS/Twine/Twine/Development/AppPaths.swift:6`<br>`macOS/Twine/TwineTests/Development/DevelopmentPathsTests.swift:40`<br>`macOS/Twine/TwineUITests/Support/TwineUITests.swift:241`<br>`macOS/Twine/TwineUITests/Traces/TraceCompletenessUITests.swift:63`<br>`macOS/Twine/TwineUITests/Traces/TraceSequenceUITests.swift:74`<br>`macOS/Twine/TwineUITests/Workflows/BentoUITests.swift:77`<br>`macOS/Twine/TwineUITests/Workflows/LocalPiWorkflowUITests.swift:61`<br>`twine-core/src/application/agents.rs:26` |
| `TWINE_HARNESS_PATH` | User-facing override | HAND-92 | `macOS/Twine/TwineUITests/Traces/TraceInspectorUITests.swift:11,138`<br>`macOS/Twine/TwineUITests/Workflows/AgentUITests.swift:12,78,162,239,284`<br>`macOS/Twine/TwineUITests/Workflows/LocalPiWorkflowUITests.swift:62`<br>`macOS/Twine/TwineUITests/Workflows/WorkflowRunUITests.swift:169`<br>`twine-core/src/application/agents.rs:27` |
| `TWINE_INTEGRATION_DIR` | Internal protocol marker or placeholder | HAND-91 | `twine-core/src/terminal/shell.rs:56,58,69` |
| `TWINE_LIGHT` | Code constant (rename outright) | HAND-90 | `twine-core/src/config/themes.rs:15,232,271,683` |
| `TWINE_MARKER` | Test/CI-only | HAND-101 | `twine-core/src/application/workflows.rs:776,801` |
| `TWINE_MEMORY_EXAMPLE_ROOT` | Test/CI-only | HAND-105 | `macOS/Twine/Twine/Development/MemoryExamples.swift:5`<br>`macOS/Twine/TwineTests/Development/DevelopmentPathsTests.swift:37` |
| `TWINE_MEMORY_INSPECTION` | Test/CI-only | HAND-105 | `macOS/Twine/Twine/Development/MemoryInspection.swift:7` |
| `TWINE_MEMORY_INSPECTION_HARNESS` | Test/CI-only | HAND-105 | `macOS/Twine/Twine/Development/MemoryInspection.swift:14` |
| `TWINE_MEMORY_INSPECTION_KIND` | Test/CI-only | HAND-105 | `macOS/Twine/Twine/Development/MemoryInspection.swift:29`<br>`macOS/Twine/TwineUITests/Memories/MemoryEditingUITests.swift:31` |
| `TWINE_MEMORY_INSPECTION_SCOPE` | Test/CI-only | HAND-105 | `macOS/Twine/Twine/Development/MemoryInspection.swift:22`<br>`macOS/Twine/TwineUITests/Memories/MemoryEditingUITests.swift:32` |
| `TWINE_MEMORY_PROTOTYPE_LAYOUT` | Test/CI-only | HAND-105 | `macOS/Twine/Twine/Development/MemoryInspection.swift:6` |
| `TWINE_NODE` | Test/CI-only | HAND-92 | `.github/workflows/pr.yml:131,132`<br>`docs/documentation/development/index.html:139`<br>`twine-core/src/harness/instructions.rs:142,144`<br>`twine-core/src/harness/opencode.rs:76,78`<br>`twine-core/src/harness/pi.rs:342,344,391,393,435,437,530,532,606,608,675,677` |
| `TWINE_NOTARY_LOG_DIR` | User-facing override | HAND-108 | `.github/release/signing.sh:78`<br>`.github/release/test-signing.sh:10,117` |
| `TWINE_NOTARY_PROFILE` | User-facing override | HAND-108 | `.github/release/signing.sh:10,76`<br>`.github/release/test-signing.sh:67,79,135,154`<br>`.github/release/with-signing.sh:36,37` |
| `TWINE_OUTPUT` | Test/CI-only | HAND-101 | `twine-core/src/application/traces.rs:795,843` |
| `TWINE_PI_PACKAGE` | Test/CI-only | HAND-92 | `twine-core/src/harness/pi.rs:530,533` |
| `TWINE_PREFERENCES_SUITE` | User-facing override | HAND-105 | `macOS/Twine/Twine/Workflows/Launch/WorkflowLaunchPreferences.swift:20`<br>`macOS/Twine/TwineTests/Workflows/WorkflowLaunchPreferencesTests.swift:11,12,20`<br>`macOS/Twine/TwineUITests/Support/TwineUITests.swift:244`<br>`macOS/Twine/TwineUITests/Workflows/LocalPiWorkflowUITests.swift:68` |
| `TWINE_READY` | Test/CI-only | HAND-101 | `macOS/Twine/TwineTests/Workflows/WorkflowTests.swift:120` |
| `TWINE_REAL_CODEX` | Test/CI-only | HAND-92 | `docs/documentation/development/index.html:125,130`<br>`twine-core/src/application/harness_steps.rs:2108,2110`<br>`twine-core/src/application/runs.rs:4449,4451` |
| `TWINE_REAL_PI` | Test/CI-only | HAND-92 | `docs/documentation/development/index.html:134`<br>`twine-core/src/application/harness_steps.rs:1403,1405` |
| `TWINE_REQUIRE_FISH_TESTS` | Test/CI-only | HAND-91 | `.github/workflows/pr.yml:125`<br>`twine-core/src/application/traces.rs:896` |
| `TWINE_REQUIRE_INJECTION` | Test/CI-only | HAND-101 | `macOS/Twine/TwineUITests/Terminal/TerminalRuntimeUITests.swift:44,71,75` |
| `TWINE_SESSION_VALUE` | Test/CI-only | HAND-101 | `macOS/Twine/TwineUITests/Windows/SessionUITests.swift:35,47,79,94`<br>`twine-core/src/application/sessions.rs:372,420` |
| `TWINE_SIGNING_DIRECTORY` | User-facing override | HAND-108 | `.github/release/test-signing.sh:147,157,159,161,163`<br>`.github/release/with-signing.sh:13` |
| `TWINE_SIGNING_KEYCHAIN` | User-facing override | HAND-108 | `.github/release/signing.sh:23,77`<br>`.github/release/test-signing.sh:67,135,152`<br>`.github/release/with-signing.sh:16,18,19,28,29,30,33,34,37` |
| `TWINE_SIGNING_MODE` | User-facing override | HAND-108 | `.github/actions/build-release/action.yml:25,35`<br>`.github/release/README.md:18,56`<br>`.github/release/bundle-artifact.sh:100,118`<br>`.github/release/signing.sh:5,13,20,26,35,75`<br>`.github/release/test-signing.sh:66,80,134,153`<br>`.github/release/validate-dmg.sh:11,16,70`<br>`.github/release/with-signing.sh:36`<br>`.github/workflows/release.yml:93`<br>`docs/documentation/development/index.html:226` |
| `TWINE_STARTUP` | Test/CI-only | HAND-101 | `twine-core/src/application/traces.rs:781` |
| `TWINE_STATUS_CURSOR_EXPIRED` | Code constant (rename outright) | HAND-88 | `macOS/Twine/Twine/Core/Transport/CoreWorker.swift:242`<br>`twine-bridge/include/twine_bridge.h:21` |
| `TWINE_STATUS_EMPTY` | Code constant (rename outright) | HAND-88 | `macOS/Twine/Twine/Core/Transport/CoreWorker.swift:67,89,126,144,151,232`<br>`twine-bridge/include/twine_bridge.h:16` |
| `TWINE_STATUS_INTERNAL_ERROR` | Code constant (rename outright) | HAND-88 | `macOS/Twine/Twine/Core/Transport/CoreWorker.swift:244`<br>`twine-bridge/include/twine_bridge.h:22` |
| `TWINE_STATUS_INVALID_ARGUMENT` | Code constant (rename outright) | HAND-88 | `macOS/Twine/Twine/Core/Transport/CoreWorker.swift:240`<br>`macOS/Twine/Twine/Core/Transport/MemoryWorker.swift:51`<br>`twine-bridge/include/twine_bridge.h:20` |
| `TWINE_STATUS_INVALID_UTF8` | Code constant (rename outright) | HAND-88 | `macOS/Twine/Twine/Core/Transport/CoreWorker.swift:236`<br>`macOS/Twine/Twine/Core/Transport/MemoryWorker.swift:49`<br>`twine-bridge/include/twine_bridge.h:18` |
| `TWINE_STATUS_MALFORMED_COMMAND` | Code constant (rename outright) | HAND-88 | `macOS/Twine/Twine/Core/Transport/CoreWorker.swift:238`<br>`macOS/Twine/Twine/Core/Transport/MemoryWorker.swift:50`<br>`twine-bridge/include/twine_bridge.h:19` |
| `TWINE_STATUS_NULL_POINTER` | Code constant (rename outright) | HAND-88 | `macOS/Twine/Twine/Core/Transport/CoreWorker.swift:234`<br>`macOS/Twine/Twine/Core/Transport/MemoryWorker.swift:48`<br>`twine-bridge/include/twine_bridge.h:17,56` |
| `TWINE_STATUS_OK` | Code constant (rename outright) | HAND-88 | `macOS/Twine/Twine/Core/Transport/CoreWorker.swift:230`<br>`macOS/Twine/Twine/Core/Transport/MemoryWorker.swift:47`<br>`twine-bridge/include/twine_bridge.h:15` |
| `TWINE_STATUS_PANIC` | Code constant (rename outright) | HAND-88 | `macOS/Twine/Twine/Core/Transport/CoreWorker.swift:246`<br>`macOS/Twine/Twine/Core/Transport/MemoryWorker.swift:52`<br>`twine-bridge/include/twine_bridge.h:23` |
| `TWINE_STATUS_TERMINAL_NOT_RUNNING` | Code constant (rename outright) | HAND-88 | `macOS/Twine/Twine/Core/Transport/CoreWorker.swift:198`<br>`twine-bridge/include/twine_bridge.h:24,170` |
| `TWINE_TEST_APPEARANCE` | Test/CI-only | HAND-105 | `macOS/Twine/Twine/TwineApp.swift:33`<br>`macOS/Twine/TwineUITests/Files/FileSyntaxHighlightingUITests.swift:167`<br>`macOS/Twine/TwineUITests/Files/GitFileTreeUITests.swift:70`<br>`macOS/Twine/TwineUITests/Terminal/TerminalMinimapUITests.swift:10`<br>`macOS/Twine/TwineUITests/Traces/TraceUITests.swift:85`<br>`macOS/Twine/TwineUITests/Windows/FolderWindowUITests.swift:13,91,138`<br>`macOS/Twine/TwineUITests/Workflows/AgentSubtabsUITests.swift:66`<br>`macOS/Twine/TwineUITests/Workflows/BentoUITests.swift:51`<br>`macOS/Twine/TwineUITests/Workflows/WorkflowRunUITests.swift:168` |
| `TWINE_TEST_DETACHED_PTY_DIRECTORY` | Test/CI-only | HAND-91 | `twine-core/src/terminal/manager.rs:1063,1079` |
| `TWINE_TEST_DETACHED_PTY_ROLE` | Test/CI-only | HAND-91 | `twine-core/src/terminal/manager.rs:1080,1500,1511` |
| `TWINE_TEST_DIR` | Test/CI-only | HAND-91 | `twine-core/src/terminal/manager.rs:1244,1246,1249,1262,1264,1322,1326,1385,1387,1390,1430,1432` |
| `TWINE_TEST_GIT` | Test/CI-only | HAND-101 | `macOS/Twine/TwineUITests/Files/GitFileTreeUITests.swift:162` |
| `TWINE_TEST_NODE` | Test/CI-only | HAND-101 | `macOS/Twine/TwineUITests/Terminal/TerminalRuntimeUITests.swift:25,79` |
| `TWINE_TEST_PID` | Test/CI-only | HAND-91 | `twine-core/src/terminal/manager.rs:691,692` |
| `TWINE_TEST_PREFERENCES_SUITE` | Test/CI-only | HAND-105 | `macOS/Twine/Twine/Workflows/Launch/WorkflowLaunchPreferences.swift:24`<br>`macOS/Twine/TwineUITests/Workflows/WorkflowRunUITests.swift:167` |
| `TWINE_UI_TEST_APP_PATH` | Test/CI-only | HAND-101 | `macOS/Twine/TwineUITests/Support/UITestSupport.swift:15` |
| `TWINE_USER_HOME` | Internal protocol marker or placeholder | HAND-91 | `twine-core/src/terminal/manager.rs:144`<br>`twine-core/src/terminal/shell.rs:77,83` |
| `TWINE_USER_ZDOTDIR` | Internal protocol marker or placeholder | HAND-91 | `twine-core/src/terminal/manager.rs:148`<br>`twine-core/src/terminal/shell.rs:54,58,65` |
| `TWINE_VALUE` | Test/CI-only | HAND-101 | `macOS/Twine/TwineUITests/Workflows/WorkflowTabsUITests.swift:15,23,33` |
| `TWINE_WINDOW` | Test/CI-only | HAND-101 | `macOS/Twine/TwineUITests/Windows/MultipleFolderUITests.swift:78,87,91,96` |
| `__TWINE_END__` | Internal protocol marker or placeholder | HAND-92 | `twine-core/src/harness.rs:35,273,383,403,419` |
| `__TWINE_OMP__` | Internal protocol marker or placeholder | HAND-92 | `twine-core/src/harness/pi-extension.js:14`<br>`twine-core/src/harness/pi.rs:23` |
| `__TWINE_HISTORY__` | Test/CI-only | HAND-101 | `twine-core/src/application/terminals.rs:520` |
| `__TWINE_ONE__` | Test/CI-only | HAND-101 | `twine-core/src/terminal/manager.rs:848,885` |
| `__TWINE_PATH__` | Internal protocol marker or placeholder | HAND-92 | `twine-core/src/harness.rs:34,273,383,403,419` |
| `__TWINE_SOCKET__` | Internal protocol marker or placeholder | HAND-92 | `twine-core/src/application/harness_steps.rs:919`<br>`twine-core/src/harness/opencode-plugin.js:8`<br>`twine-core/src/harness/opencode.rs:35`<br>`twine-core/src/harness/pi-extension.js:13`<br>`twine-core/src/harness/pi.rs:31` |
| `__TWINE_SWIFT__` | Test/CI-only | HAND-101 | `macOS/Twine/TwineTests/Core/TerminalRoutingTests.swift:126,134,171` |
| `__TWINE_TWO__` | Test/CI-only | HAND-101 | `twine-core/src/terminal/manager.rs:848,888` |

`TWINE_HARNESS_PATH` is read by production core, despite its test-oriented comment;
it is a user-facing override. The memory inspection/example knobs are development
and test tooling, so they receive no legacy fallback. `TWINE_NODE`,
`TWINE_REAL_CODEX`, `TWINE_REAL_PI`, and `TWINE_PI_PACKAGE` are inputs to ignored
integration tests, not runtime harness selection. Signing controls are supported
local packaging inputs even when CI also supplies them. `TWINE_SIGNING_KEYCHAIN`
can be supplied to signing helpers or generated by the credential wrapper; its
producer and readers must use the same precedence rule.

### Non-variable surfaces and boundaries

Each row owns the named surface everywhere it occurs. Prefix families include all
members, not just the examples shown. Mechanical renames preserve behavior unless
a migration or retention rule is explicitly stated.

| Surface / existing names | Policy and target | One owner |
| --- | --- | --- |
| `twine-core/`, `twine-bridge/`; Cargo package names, `twine_core` / `twine_bridge`, workspace entries and lockfile | Rename to `handshake-core/`, `handshake-bridge/`, `handshake_core` / `handshake_bridge`; update imports and references throughout the repository. No crate aliases. | HAND-84 |
| `twine_bridge.h`, `TWINE_BRIDGE_H`, module map, every exported `twine_*` function and every C `Twine*` type | Rename to Handshake equivalents, preserving ABI layouts, values, ownership, and behavior. Update Rust declarations, Swift callers, tests and library integration docs; no wrappers for old symbols. | HAND-88 |
| `macOS/TwineCorePackage`, `TwineCore`, `TwineCore.xcframework`, `libtwine_bridge.a`; `macOS/TwineSyntaxPackage`, `TwineSyntax`, source module directories | Rename packages/products/framework and syntax module to Handshake equivalents, including package scripts and all imports. Release archive names belong to HAND-108. | HAND-88 |
| `macOS/Twine/`, nested `Twine/`, `TwineTests/`, `TwineUITests/`, `Twine.xcodeproj`, `Twine.xcscheme`, workspace container references, `TwineApp.swift`, `Twine.entitlements`, `Twine.app`, executable `Twine` | Rename project/source paths, targets, scheme, product and executable to Handshake equivalents; update project references, test host paths, and `DevelopmentPaths` checkout detection. Packaging uses the new product under its own contract below. | HAND-95 |
| Swift internal identifiers such as `TwineApp`, `applyTwineFont`, `applyTwinePalette`, `twinePalette` | Rename product-owned identifiers to Handshake equivalents with callers and tests. Package/C names and logo artwork remain owned by their exact rows. | HAND-95 |
| `com.twineproject.Twine`, `.development`, `com.twineproject.TwineTests`, `com.twineproject.TwineUITests`, `.xctrunner`, and preference-suite strings beneath `com.twineproject.Twine.tests.*` | Keep existing bundle IDs and preference domains for this release, including tests/development isolation; preserve `workflowRoleHarnesses`, `workflowRoleModels`, zoom and layout preferences. Do not bulk-rename a product substring inside a domain. | HAND-105 |
| Swift `Logger` and Rust tracing subsystem `com.twineproject.Twine` | Preserve the exact log subsystem for this release, across Swift loggers and bridge logging. Logging continuity is intentional compatibility. | HAND-105 |
| `~/Library/Application Support/Twine/`, `twine.db` and its SQLite `-wal` / `-shm` companions; transcripts, trace payloads, metadata and presentation files | Core migrates to `Handshake/` and `handshake.db` with exclusive-writer checks, recoverability, interruption/retry safety, and existing-destination precedence. Preserve bytes, IDs and saved content. | HAND-89 |
| App/bridge selection of the production Application Support root | Wire core migration through `CoreClient`; Swift supplies platform paths. Debug/test/preview paths and explicit overrides must not adopt production data. | HAND-99 |
| `TWINE-T1`, `TWINE-S1` in `terminal/transcript/storage.rs` | Preserve existing persisted transcript and size-record magic bytes and readers. A product rename alone is not a storage format change; historical transcripts remain readable without rewriting. | HAND-89 |
| `$XDG_CONFIG_HOME/twine`, `~/.config/twine`, `twine/config.toml`, `twine/workflows` temp fallback in `store.rs`, and user workflow/config imports | Adopt `handshake` config paths only when the destination is not established. Preserve sources, custom workflows, relative imports and files. Existing Handshake destination wins; explicit overrides retain their meaning. | HAND-90 |
| `twine_light`, `twine_dark`, corresponding `.toml` files, embedded constants and generated config comments | New defaults are `handshake_light` / `handshake_dark` with unchanged colors. Continue resolving legacy selectors and customized legacy files. Preserve the Silica behavior below. | HAND-90 |
| All bundled theme comments saying to restart Twine; generated config documentation URLs | Use Handshake and current documentation URLs, without changing palettes, third-party theme names, attribution or licenses. | HAND-90 |
| Shell `_twine_*` functions/state; `twine=@TOKEN@` OSC 133 marker; shell integration temp prefix `twine-shell-` | Rename to Handshake equivalents, changing Bash/Zsh/Fish emitters and Rust stream decoder/tests together. No old marker fallback for new shell processes; saved transcript bytes remain unchanged. | HAND-91 |
| `twine-program-launcher`, `twine-shell-launcher`, `twine-terminal-`, `twine-terminal-test-` | Rename temporary launch/process labels and fixtures together; keep process, PTY and byte handling unchanged. | HAND-91 |
| `twine-observer.mjs`, `twine.js`, `twine-steps-`, `twine-agent-completion-`, `twine-completion-`, generated `twine_body`, `_twine_observation_id` | Rename generated observers, inbox/completion temp files and private event identities to Handshake equivalents; change JS producers, Rust substitution/consumption, and fixtures together. Historical imported conversation records stay intact. | HAND-92 |
| Codex `clientInfo.name = "twine"`, Antigravity customization key `"twine"`, generated workflow/role instructions and completion acknowledgment text | Use Handshake identification and instructions, with completion protocol unchanged. Change generated messages as a unit under harness ownership, including strings in workflow-run modules. | HAND-92 |
| Third-party harness paths (`.claude`, `.codex`, `.pi`, OpenCode/OMP/Antigravity data), native conversation records and encoded folder names such as `-demo-twine` | Preserve third-party names and user data. A fixture representing a historical native path may retain its spelling; change only product-generated integration files described above. | HAND-92 |
| `.twine-save-*` atomic-edit staging files | Rename new staging-file prefix to `.handshake-save-*`; preserve atomic-save behavior and existing user files. | HAND-106 |
| Worker thread labels `twine-files`, `twine-git` | Rename to Handshake equivalents with diagnostic/test expectations; preserve worker behavior. | HAND-106 |
| `twine-markdown` URL scheme in preview URL builder and renderer CSP | Rename both producer and WebKit consumer/CSP to `handshake-markdown` together with preview tests. This is an internal preview transport, not an externally registered URL API. | HAND-95 |
| `Twine Terminal Nerd Font`, `TwineHackNF*`, font name-table unique ID `3.003;TWNE;TwineHackNF-*` and corresponding font fallback lookups | Rename private family/PostScript identity and lookups together, including binary font name tables, NOTICE and resource hashes. Preserve glyphs, metrics, other tables and upstream license/copyright. Keep upstream filenames `HackNerdFont-*.ttf`. | HAND-95 |
| App menus, About, welcome, errors, settings help, permission descriptions, accessibility strings and product-owned Rust diagnostics mentioning Twine | Replace only product names with Handshake; preserve existing copy/layout/Title Case and domain terms. Generated harness instructions and config comments use their exact owners above. | HAND-106 |
| App logo resource (`.twineLogo`) and welcome-screen symbol | Replace with approved identity asset; no interface redesign. | HAND-104 |
| `twine-*.png`, `twine-debug-*.png`, old AppIcon/AppIconDebug asset sets and old Debug artwork | Wire approved `.icon` assets into Xcode and remove obsolete icon files; update consumers. Preserve bundle identity. | HAND-133 |
| `Twine-ci-<sha>` | Rename to `Handshake-ci-<sha>` atomically in upload (`ci.yml`), release guard, download (`release.yml`) and build-release action contract. HAND-101 leaves this name alone. | HAND-108 |
| `TwineBuildVersion` plist key | Rename to `HandshakeBuildVersion` in both `bundle-artifact.sh` writes and `validate-dmg.sh` reads. No compatibility alias is required. | HAND-108 |
| `Twine.app.zip`, `libtwinecore.a`, `Twine-VERSION-macos-arm64.dmg`, `libtwinecore-VERSION-macos-arm64.tar.gz`, `twine-VERSION-source.tar.gz`, source archive root `twine-VERSION/` | Produce Handshake equivalents with `libhandshakecore.a`, preserving checksums, architecture, signatures and notarization checks. Update library README, artifact collection, release validation and consumers. Preserve already published historical downloads. | HAND-108 |
| DMG `Twine — Drag to Applications`, Finder `Twine.app` layout/Iloc keys, signing temp prefix `twine-signing.*`, notary profile value `twine-release` | Rename packaging labels, layout producers/validators, credential creation and consumption together; preserve cleanup and signing guarantees. | HAND-108 |
| DMG background SVG/TIFF, rendering script, checked-in installer previews and artwork docs | Replace product artwork and any wordmark with approved assets. The ordinary English word `intertwined` is not a product identifier. | HAND-93 |
| `twine-release-published` repository dispatch event | Rename to `handshake-release-published` with both tap receivers coordinated; version is `0.4.0`, adding a changelog section without rewriting old sections. | HAND-110 |
| `TwineProject/homebrew-tap`, `twineproject/tap` | Keep the compatibility repository/tap identity; prepare `handshake` cask and direct `twine-app` / `twine-ade` mappings there. | HAND-97 |
| Primary `standing-desks/tap/twine-ade`, old `twine-app` cask metadata and tap migration mappings | Prepare `standing-desks/tap/handshake`; preserve upgrade mappings and user data. Product-repo install examples follow their docs/site owners. | HAND-96 |
| `standing-desks/twine` GitHub repository identity | Rename remote repository to `standing-desks/handshake`; remote execution requires its issue's approval. | HAND-116 |
| GitHub descriptions, homepage and social artwork, including primary tap's old `aravind-n/twine` homepage | Update remote metadata and verify integration/branch protections; keep compatibility tap identity. | HAND-117 |
| `docs/index.html`, `docs/assets/download.js`, `docs/assets/twine-rounded.svg`, current `/twine/` canonical/social/download URLs, web product copy and install commands | Use Handshake URLs, name, approved symbol/wordmark and download artifact patterns; preserve existing interface design scope. | HAND-94 |
| Existing public `/twine/` site pages and anchors | Prepare explicit legacy redirects to `/handshake/` equivalents. Old release URLs remain historical downloads. | HAND-86 |
| `docs/assets/workspace.png`, screenshot alt text mentioning Twine | Refresh from disposable branded app state; preserve privacy. | HAND-109 |
| `README.md`, `CONTRIBUTING.md`, `docs/documentation/`, Swift DocC and package docs: product names, commands, module/API links, update API URL and HTTP User-Agent in `UpdateCommands.swift` | Update current documentation and product update links to Handshake; explain migrations, legacy inputs and manual replacement. Exact variable/API changes belong to the contract owners above, even in docs. | HAND-107 |
| Root `AGENTS.md`, `CONTEXT.md`, reviewer definitions in `.claude/agents/` and `.codex/agents/` | Handshake vocabulary and target components; keep domain terms and architecture. HAND-83 established these rules. | HAND-83 |
| Component `AGENTS.md` files and all instruction references to moved component paths | Update after directory renames, including root and reviewer filesystem references; preserve architecture. | HAND-98 |
| Makefile, CI path filters/cache inputs, setup-build, Dependabot, ignore rules, `clean-dev-state.sh`, DocC/Rustdoc/site build commands and source/hosting paths | Follow new crate/project/package paths, test selectors/products and site base `handshake/documentation/swift`; include assets filters. Keep job/check names, especially `Required PR checks`, stable. Cleanup remains limited to development/test state and retained bundle domains. Exact variable/artifact rows override this family. | HAND-101 |
| `TWINE44_TRACE_SMOKE`, `TWINE45_TRACE_SMOKE` integration prompts and matching trace assertions | Rename outright with the real-harness fixture prompts and observer assertions together. | HAND-92 |
| General test labels/temp paths (`Twine*Tests-*`, `Twine*UITests*`, `twine-test*`, `.twine`, `.twine-data`, `twine.pid`, `twine-real-adversarial-output.txt`), test module names and local fixture strings | Rename synthetic product-owned names outright and keep assertions in sync. Bundle domains, native harness history fixtures, variables and specialized protocol tests follow exact owners above. Do not rewrite real user content. | HAND-101 |
| `CHANGELOG.md` old releases, ADR 0008 `TWINE-62` issue/provenance links, third-party licenses and copyright, ordinary `intertwined` matches | Preserve historical and third-party text; retain all earlier release versions/downloads. Final audit records these deliberate exceptions, rather than replacing substrings. | HAND-114 |

### Silica and config compatibility

HAND-90 must preserve the behavior implemented by `config/themes.rs::publish`
and its inline migration tests, rather than treating Silica as another branding
string to replace:

- If a current default theme file already exists, leave it untouched. It wins over
  a customized older Silica file.
- When a current default file is missing, compare `silica_light.toml` or
  `silica_dark.toml` with its corresponding embedded Silica source. An untouched
  Silica file adopts the current default palette; a customized file is copied
  forward once, preserving its content and the original source file.
- Later edits to the Silica source do not overwrite an established destination.
  Explicit `silica_light` / `silica_dark` selections and bundled Silica files stay
  available. Preserve other bundled theme names and colors.
- An unreadable or non-UTF-8 legacy file yields a diagnostic and leaves the new
  default absent, so a later load retries after repair. An unused default's failed
  migration does not block a separately selected valid theme (the existing test
  selects `nord`). Do not turn a read failure into a successful default migration.
- During the Handshake migration, an established Handshake theme wins; otherwise
  retain customized Twine defaults and old selectors as readable inputs, while
  retaining the Silica rules for earlier installations. Preserve import ordering,
  relative paths and inline overrides. Color values do not change in this rebrand.

### External consumers and API shims

No external consumer requiring a C/Rust/Swift API compatibility shim has been
identified in the tracked checkout or the rebrand issues. The in-tree Swift app,
Swift packages, bridge, release-library example and tests are coordinated
consumers; a distributed library archive alone is not evidence of an external
consumer that requires old symbols. HAND-88 therefore renames the API outright
without old-symbol wrappers or package aliases. Record a concrete consumer and
its required contract before adding any such shim.

Known external continuity contracts are different: installed apps retain bundle
and preference identity, users retain saved data/config/themes and supported
launch overrides, Homebrew users retain upgrade paths in both taps, and public
legacy site/release links remain useful. Their owners and policies are above.
Native harness histories belong to the third-party tool/user, and are read without
rewriting. The inventory cannot prove that no unknown external integration exists;
it records that none requiring an API alias has been evidenced.

## Consequences

A contract owner may edit files usually associated with another issue so that a
rename remains atomic. Coordinate overlapping files instead of splitting the
same variable between Rust, Swift and automation work. The final audit compares
remaining names with the retained compatibility/history policies here and reports
newly discovered consumers before extending compatibility.

## Source index and audit method

This is a snapshot of baseline `cf44f71ed8742ef1093c70c891b48d41c0aff5e2` before this ADR.
Searches used `git grep -in twine` (including binary-match reports),
`git grep -n TWINE_`, and `git ls-files` with a case-insensitive path match.
The tables cover all uppercase tokens, including non-environment constants,
placeholders, Xcode wrappers, and synthetic output markers. The families above
cover every other match and every tracked path containing the product name.

The textual source index below records every matching file and its baseline line
numbers, excluding the temporary design reference. Look up a name's owner in the
contract tables, rather than assigning every occurrence in a file to one issue.
The index is historical: later edits and renames will move these coordinates.
Binary font matches are covered by the private-font row; image assets and paths
without textual matches are covered by the icon/logo/artwork and directory rows.
All descendants of the old macOS/crate/package paths follow those directory rules,
even files whose content contains no product name. Existing font and theme license
text is retained under the third-party policy, not blindly rewritten.

| Baseline file | Matching lines |
| --- | --- |
| `.claude/agents/rust-reviewer.md` | 14, 33, 110 |
| `.claude/agents/swift-reviewer.md` | 14 |
| `.codex/agents/rust-reviewer.toml` | 11, 30, 107 |
| `.codex/agents/swift-reviewer.toml` | 11 |
| `.github/actions/build-release/action.yml` | 25, 27, 35, 37 |
| `.github/actions/setup-build/action.yml` | 63 |
| `.github/dependabot.yml` | 9, 10 |
| `.github/release/README.md` | 17, 18, 25, 34, 56 |
| `.github/release/build-dmg.sh` | 28, 32 |
| `.github/release/bundle-artifact.sh` | 39, 41, 58, 59, 60, 64, 67, 68, 69, 70, 71, 86, 87, 92, 95, 100, 101, 102, 105, 107, 108, 109, 110, 114, 115, 116, 118 |
| `.github/release/dmg-layout.py` | 32, 75 |
| `.github/release/installer-background.svg` | 1 |
| `.github/release/library-README.txt` | 1, 3, 4, 8, 11, 12, 16, 19, 20 |
| `.github/release/signing.sh` | 5, 10, 13, 20, 23, 26, 35, 65, 75, 76, 77, 78 |
| `.github/release/test-signing.sh` | 10, 66, 67, 79, 80, 84, 93, 117, 134, 135, 147, 152, 153, 154, 157, 159, 161, 163 |
| `.github/release/validate-dmg.sh` | 11, 16, 40, 44, 48, 49, 55, 56, 60, 70 |
| `.github/release/with-signing.sh` | 13, 15, 16, 18, 19, 28, 29, 30, 33, 34, 36, 37 |
| `.github/workflows/ci.yml` | 33 |
| `.github/workflows/notify-tap.yml` | 23, 46 |
| `.github/workflows/pr.yml` | 55, 56, 75, 125, 131, 132 |
| `.github/workflows/release.yml` | 43, 71, 93, 96 |
| `.gitignore` | 17, 18, 19, 20, 21, 22 |
| `AGENTS.md` | 24, 25 |
| `CHANGELOG.md` | 32, 78, 79, 142, 173, 194, 195, 196, 198, 199, 203, 208, 215, 232, 237, 259, 266, 267, 268, 269, 270, 271, 272, 273, 274, 275, 276, 277 |
| `CONTEXT.md` | 58 |
| `CONTRIBUTING.md` | 25, 26, 37, 69, 70, 74, 75 |
| `Cargo.lock` | 635, 645, 649 |
| `Cargo.toml` | 2 |
| `Makefile` | 6, 11, 19, 20, 33, 98, 99, 100, 162, 167, 168, 169, 170, 171, 179, 188, 199, 204, 227, 265, 266, 268, 281, 282, 284, 285, 286, 287, 288, 290 |
| `README.md` | 2, 5, 10, 11, 12, 14, 20, 24, 29, 34, 37, 40, 41, 44, 53, 81, 82, 87, 91, 94, 96, 97, 98, 99, 113, 130, 144, 148, 155, 157, 160, 170, 171, 185, 186, 188, 192, 209, 210, 211, 213, 221, 227, 232 |
| `docs/adr/0008-git-status-default-worktree.md` | 5, 6, 10 |
| `docs/adr/README.md` | 9 |
| `docs/assets/download.js` | 26, 34, 43 |
| `docs/documentation/development/index.html` | 7, 8, 9, 16, 17, 36, 41, 43, 44, 52, 68, 77, 88, 90, 99, 102, 125, 130, 134, 139, 142, 181, 190, 194, 201, 202, 203, 205, 214, 226, 232, 235 |
| `docs/documentation/guide/index.html` | 7, 8, 9, 16, 17, 36, 41, 44, 46, 48, 50, 51, 52, 55, 56, 60, 64, 84, 102, 134, 137, 204, 207, 208, 241, 243, 244, 245, 247, 249, 271, 272, 276, 283, 284, 297, 308, 318, 348, 353, 362, 377, 384, 390, 393, 398, 399, 402 |
| `docs/documentation/index.html` | 7, 8, 9, 16, 17, 22, 27, 30, 32, 33, 36, 43, 44, 45, 47 |
| `docs/documentation/rust/index.html` | 5, 6, 8 |
| `docs/index.html` | 7, 8, 9, 11, 13, 14, 24, 26, 31, 42, 43, 50, 52, 54, 58, 59, 120, 123, 126, 127, 134, 136, 140, 144, 151, 152 |
| `macOS/AGENTS.md` | 3, 7, 9, 15, 41, 42, 47, 48 |
| `macOS/Twine/Artwork/AppIconDebug.svg` | 2, 3 |
| `macOS/Twine/Twine.xcodeproj/project.pbxproj` | 11, 13, 14, 23, 30, 35, 36, 37, 38, 42, 44, 47, 49, 52, 54, 63, 65, 85, 86, 87, 88, 96, 97, 98, 106, 108, 117, 119, 121, 123, 126, 127, 130, 132, 144, 146, 147, 148, 151, 153, 165, 167, 168, 169, 195, 205, 207, 216, 217, 218, 227, 263, 268, 274, 340, 401, 407, 427, 428, 429, 430, 431, 432, 434, 435, 436, 437, 438, 439, 440, 441, 447, 465, 471, 491, 492, 493, 494, 495, 496, 498, 499, 500, 501, 502, 503, 504, 505, 511, 529, 539, 546, 550, 560, 567, 571, 579, 586, 590, 598, 605, 612, 615, 616, 620, 623, 624, 628, 631, 632, 636, 639, 640, 647, 649, 651, 653, 690, 692, 693, 700, 702, 703 |
| `macOS/Twine/Twine.xcodeproj/xcshareddata/xcschemes/Twine.xcscheme` | 19, 20, 38, 39, 48, 49, 70, 71, 86, 87 |
| `macOS/Twine/Twine/Assets.xcassets/AppIcon.appiconset/Contents.json` | 7, 13, 19, 25, 31, 37, 43, 49, 55, 61 |
| `macOS/Twine/Twine/Assets.xcassets/AppIconDebug.appiconset/Contents.json` | 7, 13, 19, 25, 31, 37, 43, 49, 55, 61 |
| `macOS/Twine/Twine/Assets.xcassets/TwineLogo.imageset/Contents.json` | 4 |
| `macOS/Twine/Twine/Assets.xcassets/TwineLogo.imageset/twine-rounded.svg` | 2 |
| `macOS/Twine/Twine/Commands/UpdateCommands.swift` | 26, 30, 36, 49, 55 |
| `macOS/Twine/Twine/Core/Client/CoreClient+Lifecycle.swift` | 4, 7 |
| `macOS/Twine/Twine/Core/Client/CoreClient.swift` | 6, 252, 330 |
| `macOS/Twine/Twine/Core/Client/TerminalChunkRouter.swift` | 1 |
| `macOS/Twine/Twine/Core/Protocol/CoreModels.swift` | 122 |
| `macOS/Twine/Twine/Core/Transport/CoreTransport.swift` | 30, 32, 34, 36, 38, 40, 42, 44, 46, 48, 52, 54, 56, 58 |
| `macOS/Twine/Twine/Core/Transport/CoreWorker.swift` | 2, 21, 27, 38, 41, 59, 62, 67, 79, 84, 87, 88, 89, 100, 103, 113, 115, 122, 124, 126, 142, 144, 146, 149, 150, 151, 171, 185, 197, 198, 203, 205, 216, 224, 228, 230, 232, 234, 236, 238, 240, 242, 244, 246, 257, 258, 264, 266, 279, 280, 291, 292, 300, 302, 309, 311, 318, 320, 327, 329, 336, 337 |
| `macOS/Twine/Twine/Core/Transport/MemoryWorker.swift` | 2, 9, 11, 20, 22, 31, 33, 39, 40, 45, 47, 48, 49, 50, 51, 52 |
| `macOS/Twine/Twine/Development/AppPaths.swift` | 6, 12 |
| `macOS/Twine/Twine/Development/DevelopmentPaths.swift` | 6, 14 |
| `macOS/Twine/Twine/Development/MemoryExamples.swift` | 5 |
| `macOS/Twine/Twine/Development/MemoryInspection.swift` | 6, 7, 14, 22, 29 |
| `macOS/Twine/Twine/Documentation.docc/Twine.md` | 1, 7, 9, 15, 17, 23 |
| `macOS/Twine/Twine/Files/Browser/FileBrowserModel.swift` | 5 |
| `macOS/Twine/Twine/Files/Browser/FileTreeContextMenu.swift` | 18 |
| `macOS/Twine/Twine/Files/Editor/FileEditorModel.swift` | 5, 7 |
| `macOS/Twine/Twine/Files/Editor/FileTextView.swift` | 3 |
| `macOS/Twine/Twine/Files/Editor/FileViewer.swift` | 2 |
| `macOS/Twine/Twine/Files/Editor/Syntax/FileSyntaxHighlighter.swift` | 3, 5 |
| `macOS/Twine/Twine/Files/Editor/Syntax/FileSyntaxMode.swift` | 1 |
| `macOS/Twine/Twine/Files/Editor/Syntax/FileSyntaxRenderer.swift` | 2 |
| `macOS/Twine/Twine/Files/Preview/HTML/HTMLWebView.swift` | 6 |
| `macOS/Twine/Twine/Files/Preview/Markdown/MarkdownAssetHandler.swift` | 6 |
| `macOS/Twine/Twine/Files/Preview/Markdown/MarkdownPreviewURL.swift` | 4 |
| `macOS/Twine/Twine/Files/Preview/Markdown/MarkdownRenderer.swift` | 35 |
| `macOS/Twine/Twine/Harnesses/HarnessModelCatalog.swift` | 5 |
| `macOS/Twine/Twine/Settings/SettingsPopup.swift` | 5 |
| `macOS/Twine/Twine/Terminal/Minimap/TerminalMinimapState.swift` | 83 |
| `macOS/Twine/Twine/Terminal/Rendering/Fonts/HackNerdFont-NOTICE.txt` | 1, 8, 9, 10, 16, 17, 19 |
| `macOS/Twine/Twine/Terminal/Rendering/MetalTerminalView.swift` | 9, 163, 171, 178, 202, 223, 224, 233 |
| `macOS/Twine/Twine/Terminal/Rendering/TerminalController.swift` | 8, 11, 136 |
| `macOS/Twine/Twine/Terminal/Rendering/TerminalSurface.swift` | 178, 180, 198, 207 |
| `macOS/Twine/Twine/TwineApp.swift` | 2, 3, 13, 29, 30, 33 |
| `macOS/Twine/Twine/Windows/ContentView.swift` | 3, 13, 15, 68 |
| `macOS/Twine/Twine/Windows/FolderView.swift` | 5 |
| `macOS/Twine/Twine/Windows/FolderWindows.swift` | 5 |
| `macOS/Twine/Twine/Windows/Sidebar/FolderSidebar.swift` | 5 |
| `macOS/Twine/Twine/Windows/StartPage.swift` | 26, 32, 61, 63, 176 |
| `macOS/Twine/Twine/Workflows/Launch/WorkflowLaunchPreferences.swift` | 20, 24 |
| `macOS/Twine/Twine/Workflows/Workspace/WorkflowLayouts.swift` | 5 |
| `macOS/Twine/Twine/Workflows/Workspace/WorkflowTerminalSurface.swift` | 69 |
| `macOS/Twine/Twine/Workflows/Workspace/WorkflowWorkspace.swift` | 4 |
| `macOS/Twine/TwineTests/Commands/ReleaseUpdateCheckTests.swift` | 4, 57 |
| `macOS/Twine/TwineTests/Core/AgentWorkflowTests.swift` | 4 |
| `macOS/Twine/TwineTests/Core/CoreClientTests.swift` | 5, 141 |
| `macOS/Twine/TwineTests/Core/FolderTests.swift` | 4 |
| `macOS/Twine/TwineTests/Core/TerminalChunkRouterTests.swift` | 4 |
| `macOS/Twine/TwineTests/Core/TerminalDeliveryTests.swift` | 6, 23 |
| `macOS/Twine/TwineTests/Core/TerminalRoutingTests.swift` | 6, 102, 108, 126, 134, 171 |
| `macOS/Twine/TwineTests/Core/WorkflowRunTests.swift` | 4, 31 |
| `macOS/Twine/TwineTests/Design/DesignTests.swift` | 6 |
| `macOS/Twine/TwineTests/Design/RoleStyleTests.swift` | 5 |
| `macOS/Twine/TwineTests/Development/DevelopmentPathsTests.swift` | 4, 14, 15, 21, 22, 28, 37, 40, 46 |
| `macOS/Twine/TwineTests/Files/FileAutosaveTests.swift` | 4 |
| `macOS/Twine/TwineTests/Files/FileBrowserTests.swift` | 5 |
| `macOS/Twine/TwineTests/Files/FileEditorTests.swift` | 4 |
| `macOS/Twine/TwineTests/Files/FileGitTests.swift` | 4, 50 |
| `macOS/Twine/TwineTests/Files/FileLineNumberTests.swift` | 3 |
| `macOS/Twine/TwineTests/Files/FileSyntaxParserTests.swift` | 3 |
| `macOS/Twine/TwineTests/Files/FileSyntaxRenderingTests.swift` | 3, 5 |
| `macOS/Twine/TwineTests/Files/FileTabsTests.swift` | 4 |
| `macOS/Twine/TwineTests/Files/HTMLPreviewReloadTests.swift` | 6 |
| `macOS/Twine/TwineTests/Files/HTMLPreviewTests.swift` | 6 |
| `macOS/Twine/TwineTests/Files/HTMLPreviewZoomTests.swift` | 6, 17 |
| `macOS/Twine/TwineTests/Files/MarkdownPreviewTests.swift` | 6, 17 |
| `macOS/Twine/TwineTests/Harnesses/HarnessModelTests.swift` | 4 |
| `macOS/Twine/TwineTests/Memories/MemoryBridgeTests.swift` | 5, 11, 45 |
| `macOS/Twine/TwineTests/Memories/MemoryModelTests.swift` | 4 |
| `macOS/Twine/TwineTests/Memories/MemoryNavigationTests.swift` | 5 |
| `macOS/Twine/TwineTests/Settings/SettingsEditorTests.swift` | 5, 65, 85, 100, 109, 128 |
| `macOS/Twine/TwineTests/Support/CoreSnapshot+TestFixtures.swift` | 1 |
| `macOS/Twine/TwineTests/Support/CoreTransport+TestDefaults.swift` | 1 |
| `macOS/Twine/TwineTests/Support/DeferredMemoryTransport.swift` | 3 |
| `macOS/Twine/TwineTests/Support/DelayedStartTransport.swift` | 3 |
| `macOS/Twine/TwineTests/Support/TemporaryPath.swift` | 6 |
| `macOS/Twine/TwineTests/Support/TranscriptFixtureTransport.swift` | 3 |
| `macOS/Twine/TwineTests/Terminal/MetalTerminalViewTests.swift` | 6, 27, 30, 38, 87 |
| `macOS/Twine/TwineTests/Terminal/TerminalAttachmentsTests.swift` | 4 |
| `macOS/Twine/TwineTests/Terminal/TerminalControllerTests.swift` | 6 |
| `macOS/Twine/TwineTests/Terminal/TerminalCursorStyleTests.swift` | 6 |
| `macOS/Twine/TwineTests/Terminal/TerminalFontTests.swift` | 5, 9, 26, 31, 54, 67, 69, 71, 72, 73 |
| `macOS/Twine/TwineTests/Terminal/TerminalHistoryTests.swift` | 6 |
| `macOS/Twine/TwineTests/Terminal/TerminalHistoryTextTests.swift` | 4 |
| `macOS/Twine/TwineTests/Terminal/TerminalMinimapInteractionTests.swift` | 5 |
| `macOS/Twine/TwineTests/Terminal/TerminalMinimapTests.swift` | 5 |
| `macOS/Twine/TwineTests/Terminal/TerminalPaletteTests.swift` | 7, 29, 33 |
| `macOS/Twine/TwineTests/Terminal/TerminalReplayTests.swift` | 6 |
| `macOS/Twine/TwineTests/Terminal/TerminalRestorationTests.swift` | 6 |
| `macOS/Twine/TwineTests/Terminal/TerminalStatusMessageTests.swift` | 3 |
| `macOS/Twine/TwineTests/Traces/TraceActivityTests.swift` | 4 |
| `macOS/Twine/TwineTests/Traces/TraceLaneStyleTests.swift` | 4 |
| `macOS/Twine/TwineTests/Traces/TraceMinimapTests.swift` | 3 |
| `macOS/Twine/TwineTests/Traces/TraceSequenceTests.swift` | 3 |
| `macOS/Twine/TwineTests/Traces/TraceTests.swift` | 4 |
| `macOS/Twine/TwineTests/Windows/FolderWindowsTests.swift` | 4 |
| `macOS/Twine/TwineTests/Windows/WindowContentTests.swift` | 3 |
| `macOS/Twine/TwineTests/Windows/WorkflowFooterTests.swift` | 4, 50 |
| `macOS/Twine/TwineTests/Workflows/MultiAgentWorkflowTests.swift` | 6, 169 |
| `macOS/Twine/TwineTests/Workflows/PaneDividerZoomTests.swift` | 4 |
| `macOS/Twine/TwineTests/Workflows/TerminalSplitTests.swift` | 5 |
| `macOS/Twine/TwineTests/Workflows/WorkflowCanvasPresentationTests.swift` | 4 |
| `macOS/Twine/TwineTests/Workflows/WorkflowDesignerGraphExamplesTests.swift` | 5 |
| `macOS/Twine/TwineTests/Workflows/WorkflowDesignerTests.swift` | 5 |
| `macOS/Twine/TwineTests/Workflows/WorkflowGraphTests.swift` | 5, 162 |
| `macOS/Twine/TwineTests/Workflows/WorkflowIndividualModeTests.swift` | 4 |
| `macOS/Twine/TwineTests/Workflows/WorkflowLaunchPreferencesTests.swift` | 4, 9, 10, 11, 12, 20, 31, 61, 80, 91, 100 |
| `macOS/Twine/TwineTests/Workflows/WorkflowLayoutTests.swift` | 6 |
| `macOS/Twine/TwineTests/Workflows/WorkflowTests.swift` | 7, 26, 64, 118, 120, 182 |
| `macOS/Twine/TwineTests/Zoom/AppZoomLayoutTests.swift` | 6, 11, 19, 51, 57 |
| `macOS/Twine/TwineTests/Zoom/AppZoomTests.swift` | 4, 8, 27, 37 |
| `macOS/Twine/TwineUITests/Commands/FolderCommandsUITests.swift` | 3, 6, 10, 24, 34 |
| `macOS/Twine/TwineUITests/Files/FileBrowserUITests.swift` | 4, 7 |
| `macOS/Twine/TwineUITests/Files/FileEditingUITests.swift` | 4, 245, 252, 253 |
| `macOS/Twine/TwineUITests/Files/FileSyntaxHighlightingUITests.swift` | 3, 6, 52, 57, 106, 117, 143, 167, 193, 198 |
| `macOS/Twine/TwineUITests/Files/FileTreeContextMenuUITests.swift` | 4, 7, 33, 62, 69 |
| `macOS/Twine/TwineUITests/Files/GitFileTreeUITests.swift` | 4, 7, 59, 70, 162, 165 |
| `macOS/Twine/TwineUITests/Files/HTMLPreviewUITests.swift` | 3, 17, 65 |
| `macOS/Twine/TwineUITests/Files/MarkdownPreviewUITests.swift` | 3, 6 |
| `macOS/Twine/TwineUITests/Memories/MemoryDockUITests.swift` | 4, 78 |
| `macOS/Twine/TwineUITests/Memories/MemoryEditingUITests.swift` | 5, 8, 31, 32, 145, 149, 162 |
| `macOS/Twine/TwineUITests/Memories/MemoryViewerUITests.swift` | 4, 7, 11, 27, 108 |
| `macOS/Twine/TwineUITests/Settings/SettingsUITests.swift` | 3, 6, 7, 15, 16, 71, 72, 85 |
| `macOS/Twine/TwineUITests/Support/TraceInspectorFixtures.swift` | 3, 44 |
| `macOS/Twine/TwineUITests/Support/TwineUITests.swift` | 2, 3, 12, 24, 34, 47, 57, 65, 76, 98, 146, 183, 209, 210, 227, 230, 241, 244, 248, 263 |
| `macOS/Twine/TwineUITests/Support/UITestSupport.swift` | 12, 15, 124 |
| `macOS/Twine/TwineUITests/Terminal/TerminalHistoryUITests.swift` | 3, 6, 41, 67, 92 |
| `macOS/Twine/TwineUITests/Terminal/TerminalMinimapUITests.swift` | 3, 7, 10, 18, 30 |
| `macOS/Twine/TwineUITests/Terminal/TerminalRuntimeUITests.swift` | 3, 6, 25, 37, 44, 45, 50, 71, 75, 79 |
| `macOS/Twine/TwineUITests/Traces/TraceCompletenessUITests.swift` | 4, 7, 63, 66 |
| `macOS/Twine/TwineUITests/Traces/TraceInspectorUITests.swift` | 3, 11, 78, 79, 138, 224, 225 |
| `macOS/Twine/TwineUITests/Traces/TraceSequenceUITests.swift` | 4, 7, 74, 77 |
| `macOS/Twine/TwineUITests/Traces/TraceUITests.swift` | 4, 85, 140, 141, 152, 157 |
| `macOS/Twine/TwineUITests/Windows/FolderWindowUITests.swift` | 3, 11, 13, 91, 138, 218 |
| `macOS/Twine/TwineUITests/Windows/MultipleFolderUITests.swift` | 4, 7, 8, 9, 10, 71, 72, 78, 87, 91, 96, 118, 119, 129, 143, 144, 180, 181, 182, 197 |
| `macOS/Twine/TwineUITests/Windows/SessionUITests.swift` | 3, 6, 35, 47, 79, 85, 86, 94, 109, 110 |
| `macOS/Twine/TwineUITests/Workflows/AgentSubtabsUITests.swift` | 4, 7, 39, 64, 66 |
| `macOS/Twine/TwineUITests/Workflows/AgentUITests.swift` | 4, 12, 78, 162, 167, 184, 211, 214, 223, 224, 239, 284, 350, 358 |
| `macOS/Twine/TwineUITests/Workflows/BentoUITests.swift` | 4, 7, 49, 51, 77, 180, 215 |
| `macOS/Twine/TwineUITests/Workflows/LocalPiWorkflowUITests.swift` | 5, 9, 11, 61, 62, 65, 66, 67, 68 |
| `macOS/Twine/TwineUITests/Workflows/TerminalSplitUITests.swift` | 4, 7, 43, 44, 53 |
| `macOS/Twine/TwineUITests/Workflows/WorkflowDesignerLifecycleUITests.swift` | 3 |
| `macOS/Twine/TwineUITests/Workflows/WorkflowDesignerUITests.swift` | 3, 47, 50, 72 |
| `macOS/Twine/TwineUITests/Workflows/WorkflowGraphExamplesUITests.swift` | 3, 120 |
| `macOS/Twine/TwineUITests/Workflows/WorkflowRunUITests.swift` | 3, 156, 167, 168, 169 |
| `macOS/Twine/TwineUITests/Workflows/WorkflowTabsUITests.swift` | 4, 15, 23, 33, 89, 109 |
| `macOS/Twine/TwineUITests/Zoom/AppZoomBoundaryUITests.swift` | 4, 7 |
| `macOS/Twine/TwineUITests/Zoom/AppZoomPreviewUITests.swift` | 4, 7, 106 |
| `macOS/Twine/TwineUITests/Zoom/AppZoomUITests.swift` | 4, 7, 102, 111 |
| `macOS/TwineCorePackage/Package.swift` | 6, 13, 21, 24, 27 |
| `macOS/TwineCorePackage/build.sh` | 7, 11, 12, 13, 14, 19, 21, 23 |
| `macOS/TwineCorePackage/select.sh` | 7, 10, 12, 13, 15, 16, 17 |
| `macOS/TwineSyntaxPackage/Package.swift` | 6, 8, 33 |
| `macOS/TwineSyntaxPackage/README.md` | 1, 3, 7, 11, 39 |
| `macOS/TwineSyntaxPackage/Sources/TwineSyntax/SyntaxLanguage.swift` | 22 |
| `macOS/TwineSyntaxPackage/Sources/TwineSyntax/SyntaxParser.swift` | 12 |
| `scripts/clean-dev-state.sh` | 6, 17 |
| `twine-bridge/AGENTS.md` | 3 |
| `twine-bridge/Cargo.toml` | 2, 17 |
| `twine-bridge/include/module.modulemap` | 1, 2 |
| `twine-bridge/include/twine_bridge.h` | 1, 2, 12, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 27, 29, 32, 34, 37, 38, 42, 43, 44, 47, 48, 49, 52, 53, 54, 56, 59, 66, 69, 71, 73, 75, 78, 83, 84, 87, 90, 94, 95, 102, 103, 104, 106, 107, 110, 112, 113, 116, 117, 120, 125, 126, 127, 129, 130, 131, 133, 134, 135, 140, 141, 142, 146, 147, 150, 151, 152, 157, 161, 162, 163, 165, 166, 170, 172, 173, 180, 181, 187, 188, 197, 200 |
| `twine-bridge/src/client.rs` | 4, 10, 14, 28, 100, 101, 114, 115, 129, 140, 143, 150, 161, 162, 177, 211, 212 |
| `twine-bridge/src/error.rs` | 2, 7, 9 |
| `twine-bridge/src/ffi.rs` | 5, 16, 31, 36, 63, 66, 69, 74, 78, 82, 87, 90, 93, 100, 105, 125, 128, 129, 140, 141, 143, 149, 152, 156, 191, 222, 224, 225, 237, 238, 248, 251, 252, 259, 261, 262, 263, 264, 265, 266, 268, 269, 270, 272, 273, 275, 276, 277, 278, 283, 284, 285, 286, 287, 291, 305, 317, 326, 333, 339, 342, 391, 417 |
| `twine-bridge/src/lib.rs` | 1, 15, 16, 18, 33, 37, 40, 48, 49, 52, 53, 68, 74, 82, 83, 84, 87, 88, 99, 104, 110, 112, 113, 116, 117, 128, 140, 141, 142, 143, 152, 161, 162, 163, 178, 180, 181, 184, 185, 199, 213, 216, 217, 226, 227, 230, 231, 239, 241, 261, 263, 278, 279, 280, 281, 282, 285, 287, 289, 299, 300, 306, 324, 325, 328, 329, 342, 354, 355, 356, 357, 362, 364, 376, 377, 380, 381, 396, 406, 407, 411, 412, 416, 426, 436, 437, 441, 442, 446, 456, 466, 467, 471, 472, 476, 486, 496, 497, 502, 503, 517, 527, 528, 531, 532, 543, 556, 557, 558, 559, 564, 569, 574, 582, 583, 587, 588, 593, 603, 614, 615, 616, 617, 627, 628, 636, 647, 648, 649, 669, 670, 674, 684, 685, 686, 690, 696, 701, 728, 729, 735, 762, 787, 790, 791, 799, 809, 812, 813, 838, 842, 843, 846, 847, 850, 851, 854, 855, 858, 859, 895, 901, 913, 914, 917, 921, 922, 926, 933, 938, 939, 942, 943, 948, 949, 952, 953, 958, 960, 963, 972, 973, 981, 985, 989, 996, 1003, 1012, 1032, 1035, 1036, 1068, 1072, 1073, 1077, 1084, 1087, 1088, 1091, 1092, 1099, 1103, 1104, 1110, 1114, 1115, 1122, 1126, 1127, 1130, 1131, 1134, 1135, 1138, 1139, 1144, 1148, 1149, 1152, 1153, 1165, 1168, 1169, 1178, 1182, 1189, 1196, 1199, 1200, 1209, 1217, 1221, 1228, 1236, 1240, 1247, 1255, 1262, 1265, 1278, 1279, 1281, 1284, 1285, 1286, 1287, 1292, 1298, 1306, 1313, 1314, 1322, 1323, 1329, 1336, 1342, 1343, 1349, 1356, 1360, 1363, 1370, 1371, 1378, 1379, 1382, 1387, 1391, 1393, 1399, 1401, 1403, 1406, 1407, 1413, 1414, 1426, 1427, 1432, 1439, 1443, 1444, 1448, 1449, 1462, 1463, 1466, 1472, 1475, 1476, 1497, 1500, 1502, 1507, 1516, 1530, 1533, 1534, 1567, 1569, 1573, 1574, 1578, 1592, 1593, 1599, 1601, 1607, 1610, 1612, 1613, 1636, 1647, 1651, 1658, 1665, 1755, 1759, 1766, 1795, 1796, 1799, 1824, 1828, 1839, 1848, 1857, 1861, 1864, 1866, 1869, 1881, 1887, 1890, 1896, 1899, 1905, 1910, 1912, 1913, 1921, 1933, 1935, 1936, 1938, 1940, 1941, 1952, 1953, 1960, 1964, 1965, 1968, 1974, 1977, 1978, 1982, 1988, 2013, 2016, 2054, 2057, 2060, 2061, 2074, 2076, 2077, 2078, 2083, 2092, 2093, 2096, 2102, 2105, 2106, 2109, 2110 |
| `twine-bridge/src/logging.rs` | 8 |
| `twine-bridge/src/memories.rs` | 2, 5, 11, 12, 15, 16, 25, 26, 29, 30, 38, 40, 50, 58, 65, 82, 83, 86, 87, 96, 105, 117, 121, 122, 125, 130, 133, 134, 137, 138, 141, 146 |
| `twine-bridge/src/protocol.rs` | 5, 91, 96, 208, 211, 255, 258, 561, 562, 580, 594, 602, 609, 673, 684, 685, 711, 712, 714, 717, 719, 739, 740, 753, 795 |
| `twine-bridge/src/protocol/files.rs` | 5, 126, 129, 130, 135, 146 |
| `twine-bridge/src/protocol/harnesses.rs` | 3, 45 |
| `twine-bridge/src/protocol/runs.rs` | 3, 19, 25, 39, 40, 255, 268 |
| `twine-bridge/src/protocol/traces.rs` | 2, 74, 214, 218, 220, 277, 287 |
| `twine-bridge/src/protocol/workflow_types.rs` | 3, 64 |
| `twine-bridge/src/protocol/workflows.rs` | 7, 344 |
| `twine-core/AGENTS.md` | 1, 3 |
| `twine-core/Cargo.toml` | 2 |
| `twine-core/src/application.rs` | 37, 257, 678 |
| `twine-core/src/application/agents.rs` | 26, 27 |
| `twine-core/src/application/harness_steps.rs` | 919, 1403, 1405, 1425, 1447, 1453, 2108, 2110, 2130, 2152, 2158 |
| `twine-core/src/application/recovery.rs` | 340, 344, 352, 383, 384 |
| `twine-core/src/application/runs.rs` | 2301, 2814, 3139, 4055, 4449, 4451, 4474, 4489, 4497 |
| `twine-core/src/application/sessions.rs` | 372, 420 |
| `twine-core/src/application/terminals.rs` | 520 |
| `twine-core/src/application/traces.rs` | 781, 795, 843, 896 |
| `twine-core/src/application/workflows.rs` | 432, 563, 776, 801 |
| `twine-core/src/config.rs` | 192, 198, 199, 275, 279, 286, 289, 377, 378, 434, 439, 444, 450, 457, 458, 767, 776, 777, 780 |
| `twine-core/src/config/editing.rs` | 193, 201 |
| `twine-core/src/config/imports.rs` | 473 |
| `twine-core/src/config/themes.rs` | 15, 16, 28, 29, 232, 233, 270, 271, 276, 277, 534, 543, 679, 680, 682, 683, 702, 744, 760, 771, 809, 813, 818, 831, 866 |
| `twine-core/src/config/themes/catppuccin_latte.toml` | 1, 2 |
| `twine-core/src/config/themes/catppuccin_mocha.toml` | 1, 2 |
| `twine-core/src/config/themes/dracula.toml` | 1, 2 |
| `twine-core/src/config/themes/gruvbox_dark.toml` | 1, 2 |
| `twine-core/src/config/themes/gruvbox_light.toml` | 1, 2 |
| `twine-core/src/config/themes/licenses/tokyo_night.txt` | 2 |
| `twine-core/src/config/themes/nord.toml` | 1, 2 |
| `twine-core/src/config/themes/silica_dark.toml` | 1 |
| `twine-core/src/config/themes/silica_light.toml` | 1 |
| `twine-core/src/config/themes/tokyo_night.toml` | 1, 2 |
| `twine-core/src/config/themes/tokyo_night_day.toml` | 1, 2 |
| `twine-core/src/config/themes/twine_dark.toml` | 1 |
| `twine-core/src/config/themes/twine_light.toml` | 1 |
| `twine-core/src/files/editing.rs` | 130 |
| `twine-core/src/files/watcher.rs` | 35 |
| `twine-core/src/folder.rs` | 11, 47, 80, 348 |
| `twine-core/src/git/status.rs` | 284 |
| `twine-core/src/git/watcher.rs` | 27 |
| `twine-core/src/harness.rs` | 34, 35, 273, 383, 387, 403, 419, 454, 460, 466, 475 |
| `twine-core/src/harness/antigravity.rs` | 4, 38, 422 |
| `twine-core/src/harness/instructions.rs` | 41, 142, 144, 179 |
| `twine-core/src/harness/instructions/codex.rs` | 38 |
| `twine-core/src/harness/models.rs` | 50 |
| `twine-core/src/harness/opencode-plugin.js` | 8 |
| `twine-core/src/harness/opencode.rs` | 33, 35, 76, 78, 80 |
| `twine-core/src/harness/pi-extension.js` | 13, 14 |
| `twine-core/src/harness/pi.rs` | 20, 23, 31, 342, 344, 391, 393, 435, 437, 530, 532, 533, 606, 608, 675, 677 |
| `twine-core/src/harness/steps.rs` | 131, 172, 310, 405, 407 |
| `twine-core/src/lib.rs` | 1 |
| `twine-core/src/memories/database.rs` | 591 |
| `twine-core/src/memories/discovery.rs` | 525, 718, 863, 865, 869, 873 |
| `twine-core/src/process.rs` | 121 |
| `twine-core/src/store.rs` | 27, 271, 279, 283, 294, 518, 581, 600, 601, 613, 1323 |
| `twine-core/src/store/harness_history.rs` | 126, 532, 567 |
| `twine-core/src/store/recovery.rs` | 28, 53 |
| `twine-core/src/store/trace_payloads.rs` | 2, 171 |
| `twine-core/src/store/trace_storage.rs` | 1 |
| `twine-core/src/store/traces.rs` | 35, 665 |
| `twine-core/src/store/workflow_types.rs` | 43 |
| `twine-core/src/terminal/launcher.rs` | 66, 92 |
| `twine-core/src/terminal/manager.rs` | 144, 148, 691, 692, 848, 885, 888, 1063, 1079, 1080, 1244, 1246, 1249, 1262, 1264, 1322, 1326, 1385, 1387, 1390, 1430, 1432, 1500, 1511, 1580 |
| `twine-core/src/terminal/process.rs` | 163 |
| `twine-core/src/terminal/shell.rs` | 1, 27, 54, 56, 58, 65, 69, 77, 83, 172, 207, 227, 234 |
| `twine-core/src/terminal/shell/bash` | 2, 3, 5, 7, 8, 9, 10, 14, 16, 17, 18, 19, 20, 22, 25, 27, 28, 29, 30, 31, 32, 33, 36, 37, 43, 44, 45, 46, 50, 54, 56, 60, 62, 64, 66, 67 |
| `twine-core/src/terminal/shell/fish` | 2, 3, 5, 6, 8, 10, 11, 13, 15, 16, 19, 20 |
| `twine-core/src/terminal/shell/zsh` | 2, 3, 6, 7, 9, 11, 12, 13, 15, 18, 20, 23, 24, 25 |
| `twine-core/src/terminal/stream.rs` | 564, 580, 584, 598, 601, 620 |
| `twine-core/src/terminal/transcript/storage.rs` | 11, 12 |
| `twine-core/src/trace.rs` | 1 |
| `twine-core/src/workflow.rs` | 40 |
| `twine-core/src/workflow_run.rs` | 739, 799, 1155 |
| `twine-core/src/workflow_run/completion.rs` | 24, 75, 94, 105, 111 |
| `twine-core/src/workflow_run/graph.rs` | 625 |
| `twine-core/src/workflow_type/builtin.rs` | 5 |
| `twine-core/src/workflow_type/catalog.rs` | 10 |
| `twine-core/src/workflow_type/files.rs` | 251 |
| `twine-core/tests/fixtures/legacy-adversarial.toml` | 1 |
| `twine-core/tests/fixtures/legacy-coordinator.toml` | 1 |
