# ADR 0010: Archive forgotten memories across the project

- Recorded: 2026-10-27
- Status: Accepted
- Provenance: Explicit maintainer decision during review of cross-agent memory sharing.
- Pull request: [#210](https://github.com/standing-desks/handshake/pull/210)

## Context

Handshake consolidates project memories in an AMIS library and delivers native
copies to participating agent profiles. Removing a memory in one agent must not
leave its shared claim available to another agent or allow a generated recap to
silently bring it back. Permanent deletion would also remove the history needed
to explain, retrieve, and reverse the decision.

## Decision

Treat forgetting a shared memory as a **project-wide archive**, regardless of
which participating agent initiated it. Retain the full content, immutable AMIS
revisions, provenance, and withdrawal evidence in the project's existing
Handshake memory library. This is archival, not secure erasure.

- Exclude archived claims and their known derived copies from automatic sharing
  and prompt refresh. Preserve suppression history across reconciliation and
  restarts; rediscovering the same claim is not permission to restore it.
- Interpret confirmed deletion of a known native memory as an archive request.
  Missing directories, failed reads, transient file replacement, index changes,
  and cleanup of obsolete projections must not silently archive unrelated claims.
- Reconcile the other native copies using the existing ownership checks and
  writer leases. Do not overwrite concurrent native edits or modify an agent's
  generated startup files to force removal.
- Make archived content available on demand in memory settings. Retrieval for
  inspection does not return it to active memory. Require an explicit **Restore**
  action to share it again, preserving the archive decision in its AMIS history.
- Keep the sidebar share toggle and settings button unchanged. Archive browsing
  is a secondary, collapsed section that appears when there is archived content.
- Apply this policy to participating harnesses generally; it is not a special
  relationship between a fixed pair of agents.

The standard macOS library remains
`~/Library/Application Support/Handshake/memories`; existing libraries retained
at the compatibility location stay in place. Archived content belongs in that
same project library, not a separate catalog that agents must request.

## Consequences and limits

Active sessions receive current shared memories through the harness's synchronous
`UserPromptSubmit` hook. The callback is bound to the launched project profile,
reconciles the local AMIS library, verifies the current native projections, and
returns native additional context before the next user turn. Trace observation
remains a separate asynchronous channel. Existing files held by live native
writers use immutable revision siblings until they can be reconciled when idle.

This refresh applies to sessions launched with the feature enabled. An older
process needs a normal resume to receive the hook; refresh does not interrupt a
streaming answer. Local consolidation does not call a model. Native memory
generation still follows the harness's own schedule and settings.

Attach the memory service before restoring agent processes at application or
window startup. A saved conversation must resume with its original native
profile and the current prompt hook. Attaching the service after restoration
cannot repair the environment of a process that has already launched.

An archive stops future Handshake delivery. It cannot erase text that an agent
has already read into an open conversation. Native file changes may wait for a
writer to become idle; live prompt refresh must exclude archived claims during
that interval. Actual delivery and verification evidence must remain distinct
from the accepted archive policy.

Suppression follows known provenance and exact claims. It does not promise
semantic detection of every independently rephrased fact. Restore is a new
explicit decision, not deletion of the prior withdrawal history.

Restore commits its decision and retained source in the canonical AMIS library
before the normal journaled publisher exposes native copies. Recovery must
finish an interrupted restore without losing the archive or overwriting a newer
native edit. A derived memory whose source is still archived stays archived
with an explanation until that source is explicitly restored.

Raw native file renames with unchanged content can preserve continuity. Renaming
an exported file with embedded ownership markers currently requires review: the
new path has no verified delivery binding, so sharing holds and preserves its
bytes. Index removal and cleanup of obsolete revision siblings do not express a
forget request; deleting the stable exported memory does, including while a
newer revision is delivered alongside it during an active session.

## Implementation and validation

Core owns archive, suppression, native reconciliation, and restoration. The
Swift UI renders core state and requests explicit actions through CoreClient.
Tests must cover both sharing directions, deletion during an active session,
retained full-content retrieval, explicit restore, restart recovery, unchanged
unrelated memories, and native file replacement races. This ADR records the
accepted policy; implementation and test completion are tracked in the PR.
