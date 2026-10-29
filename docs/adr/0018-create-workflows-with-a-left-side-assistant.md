# ADR 0018: Create workflows with a left-side assistant

- Status: Accepted
- Date: 2026-10-29

## Context

The graph designer can express agent coordination and typed Nouli decisions, but
building a reusable workflow requires knowing its configuration and routing rules.
People should be able to describe that coordination and refine it conversationally.

## Decision

Add a collapsible chat panel on the **left** of the existing workflow canvas.
Prefer the left side for assistant/chat panels. Preserve the designer's name,
Save, graph controls, and native node editors. Roll out through the app-wide
`experimental.workflow_assistant` setting, off by default and labelled Beta in
Settings. Disabling it hides the panel, rejects new generation, and cancels active
work. Manual workflow creation remains available.

The authoring harness and model are independent of each role's launch defaults
and each decision's Nouli provider/model. Initially support the installed Codex,
Claude Code, and Kiro CLI conversational commands, using the existing model catalog.
Other harnesses require an authoring adapter before appearing in this selector.

Core owns bounded background generation, process cleanup, parsing, and validation.
Each request includes the conversation and current draft. A harness works in an
empty temporary directory and returns an explanation and a complete TOML definition,
or a clarification question. Generation has a three-minute deadline, output and
conversation limits, and explicit cancellation. It does not receive the folder's
files or Handshake's agent browser integration. It uses the harness's existing
login and normal permissions. Claude's authoring command disables tools; Codex
uses a read-only sandbox; Kiro receives no trusted tools.

Only a structurally valid graph becomes an applicable revision. Show its TOML for
inspection. Applying replaces the designer draft and participates in its existing
Undo history. If the canvas changed while generation ran, require another turn
before applying. Save goes through the existing versioned catalog; core assigns
file identity and version. Saving and starting agents remain separate actions.
Validation does not imply the requested agents or Nouli provider are ready to run.

## Consequences

This reuses the existing designer and launch flow. The first implementation uses
complete responses rather than streaming tokens, and conversation state lasts for
the current designer view. Cancelling or closing the designer retains its current
canvas and stops the helper. Authoring adapters have to be checked against the
installed CLI versions. Generated configurations are subject to the same graph
limits and decision routing rules as manually authored workflows.
