# ADR 0004: Bound memory context and record explicit corrections

- Status: Accepted
- Date: 2026-10-28

## Context

Publishing a memory file does not prove that a harness includes it in a model
request. Appending every active memory to a prompt hook eventually exceeds a
consumer's inline output limit. Claude Code currently documents a 10,000-character
limit per hook string, after which it provides a file reference and short preview.
Exact-text consolidation also cannot infer that a newly saved note replaces a
different memory merely because its prose says so.

## Decision

Keep these behaviors in `handshake-core`, behind the existing opt-in memory beta.
Select byte-verified, active native memories within an 8,192-byte hook budget.
Use transient prompt terms for deterministic relevance, explicit correction intent
as a tie-breaker, and revision recency for ordering. Recency is not a truth rule.
Send whole memory bodies when they fit; otherwise provide retrieval pointers and
explicitly identify an incomplete selection. Never truncate a factual sentence or
interpret an omitted memory as withdrawn. Do not persist or log prompt text for
retrieval. Preserve the independent hook transport and native opt-outs.

Add **Correct memory…** to the existing project memory settings. A correction
identifies the selected memory and its expected revision and supplies a complete,
brief replacement. Reject stale selections, empty replacements, and replacements
over 2,000 UTF-8 bytes. Persist the old memory's archival and the new canonical
source in one AMIS bundle update before publishing native bytes. Retain immutable
history and suppress summaries with known lineage to the archived claim. Record
the exact replaced reference in `com.handshake.correction`; do not model the new
fact as derived from withdrawn guidance. This is a Handshake extension, not a new
AMIS interoperability requirement. Ordinary new notes remain ordinary new notes.

Include current corrections in the owned startup block as well as prompt context,
explicitly identifying which earlier guidance they replace. Preserve agent-owned
startup text outside that block. Existing writer leases and hash checks continue
to defer startup changes while an agent is active; its next prompt receives the
verified correction instead. Never infer authority to rewrite unrelated prose.

## Consequences

The reported combination of oversized hook output and an unresolved old claim
has a supported repair path. Existing data needs no schema migration. A user must
explicitly select the memory to correct; semantic contradiction detection and
rewriting unlinked summaries are outside this decision. Large collections still
require retrieval, and a successful hook response is not proof of model recall.

Tests must cover output pressure, current and restarted sessions, stale selections,
Unicode budgets, paused sharing, native edit conflicts, archived history, and
derived-claim suppression. Native UX tests exercise the editor and prompt hook;
authenticated consumer request inclusion and recall are separate validation.

## References

- [Claude Code hook output limits](https://code.claude.com/docs/en/hooks#json-output)
- [Core memory context](../../handshake-core/src/memories/handshake/storage/context.rs)
- [Explicit correction](../../handshake-core/src/memories/handshake/storage/correction.rs)
- [Memory correction editor](../../macOS/Handshake/Handshake/Memories/MemoryCorrectionSheet.swift)
- [Memory beta policy](0003-keep-cross-agent-memory-an-opt-in-beta.md)
