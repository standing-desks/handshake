# ADR 0005: Integrate Kiro through native V3 hooks

- Status: Accepted
- Date: 2026-10-28

## Context

Kiro CLI offers interactive V3 sessions, a native model catalog, lifecycle hooks,
and exact-ID resume. Its hooks omit prompt and tool-call identities, and resuming
a conversation restores its original named agent profile even when another
`--agent` is supplied. These constraints matter when several workflow roles use
Kiro in the same folder.

## Decision

Implement Kiro as a built-in harness in `handshake-core`. Launch `kiro-cli chat
--v3`, preserve native login and approval flows, discover models through its CLI,
and map Handshake's explicit YOLO choice to `--trust-all-tools`.
Pass initial tasks as space-prefixed positional arguments. Kiro CLI 2.35.1's V3
launcher consumes a prompt following `--`; omitting that separator preserves task
delivery, while the space keeps flag-shaped, file-shaped, and command-shaped task
text literal.

Create an exclusively leased, uniquely named temporary profile in Kiro's native
agent directory. Add observer hooks and workflow role instructions to that profile.
As with continuations, initial workflow assignments end with the recipient's
current completion command, after any commands quoted in handed-off task history.
Expose native tools explicitly with `tools: ["*"]`; an omitted tool list leaves a
custom profile unable to edit files. Tool availability does not grant permission:
leave approval rules to Kiro and the user's explicit YOLO choice.
Keep the native conversation ID and managed profile name together in Handshake's
internal session handle; recreate the same profile with fresh hooks on resume.
Retire a stopped terminal's observer before reacquiring its profile. Preserve
unowned files and prevent old cleanup from removing a successor configuration.
Existing user profiles, settings, and authentication remain native-owned.

Use the existing bounded hook transport, with typed per-launch observer state.
Only the observed root session drives prompt/response spans; additional input
during a response is recorded on that assignment. A completed tool observation
retains the supplied input and output, with an observer identity. Do not invent
native call IDs, matched start times, model calls, or child lineage. Terminal bytes
remain separate. Workflow advancement still requires the explicit completion
command; a Stop hook or process exit does not imply task success.

### Terminal divider contrast

Kiro's native dark theme draws dividers in truecolor `#262626`. The original
Handshake dark terminal background used that same color, making complete divider
rows invisible even though the terminal received and rendered them correctly.
Use `#161616` for Handshake's default dark terminal background, including the
app's fallback asset. Preserve application-supplied RGB colors, terminal output,
and Kiro's native theme and preferences.

Refresh only the byte-for-byte previous generated `handshake_dark.toml`, using
the existing version-checked atomic file save. Leave customized files, symlinks,
legacy theme sources, other themes, and explicit color overrides unchanged.
A conflicting edit wins over the default refresh. This palette correction is
separate from the rename-only color preservation recorded in ADR 0009.

## Consequences

Kiro conversations started in Handshake can resume independently in the same
folder. Existing storage can hold the internal handle without a schema migration.
A profile preparation or lease conflict rejects launch rather than silently using
the wrong profile. An abrupt process termination can leave a managed profile; a
later resume may replace it after checking its marker and acquiring its lease.

Kiro support does not add it to the Codex/Claude memory-sharing beta. Hook-only
observations cannot recover omitted history or establish native tool durations.
Native fixtures exercise UI behavior without credentials; authenticated Kiro runs
separately validate the installed version's configuration and resume semantics.

## References

- [Kiro CLI chat and persistence](https://kiro.dev/docs/cli/chat/)
- [Kiro agent configuration](https://kiro.dev/docs/custom-agents/configuration-reference/)
- [Kiro hooks](https://kiro.dev/docs/hooks/)
- [Core adapter](../../handshake-core/src/harness/kiro.rs)
