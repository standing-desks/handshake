# 0013: Name traces from prompts and recognize foreground shell agents

Status: Accepted

## Context

Assignment traces can retain generic stage labels after their prompt is known.
Terminal tabs retain the Terminal label when a user directly launches a supported
harness. The running trace marker's concentric rings can also appear hollow.

## Decision

- Preserve structured assignment task titles. Replace generic assignment labels
  with the first nonempty native prompt preview, and retain it across retries,
  follow-ups, tool activity, and restart. Track that choice separately from native
  turn identity in the trace schema. Existing history is not reconstructed from
  terminal output.
- Recognize direct foreground harness invocations from authenticated shell command
  boundaries in core. Publish the harness as a transient Terminal workflow hint;
  Swift uses it for the automatic tab title, icon, and terminal subject. Explicit
  tab names take precedence. Record the command in a harness-specific trace lane.
- Keep the same workflow kind, terminal ID, shell, and transcript. Clear the hint
  on command completion, return to prompt, integration loss, or shell exit. Late
  command observations may enrich history but cannot revive agent presentation
  after shell exit. Restoring the tab starts its shell.
- Keep shell-launched command traces distinct from native prompt/tool integration.
  Detection does not inject hooks, alter harness configuration, attach a native
  conversation, or enable single-agent cancellation/resume commands. Ambiguous
  compound, remote, background, and known administrative commands remain Terminal.
- Render running trace markers as solid lane-colored circles in both overview and
  focus views. Preserve the selection outline and failure symbol.

## Consequences

Agent naming works without restarting a shell or scraping its displayed output.
It depends on shell integration and conservatively recognizes executable names;
aliases, wrappers, and process identity verification are outside this decision.
Workflow assignments still finish only through explicit coordination signals.
Shell commands still finish through shell boundaries, not native response hooks.

## References

- [Terminology](../../CONTEXT.md)
- [Shell command recording](../../handshake-core/src/application/traces.rs)
- [Native prompt recording](../../handshake-core/src/store/harness_steps.rs)
- [Trace points](../../macOS/Handshake/Handshake/Traces/TraceFocusRail.swift)
