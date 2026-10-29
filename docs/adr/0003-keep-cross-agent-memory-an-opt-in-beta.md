# ADR 0003: Keep cross-agent memory an opt-in beta

- Status: Accepted
- Date: 2026-10-27
- Related issue: [HAND-81](https://linear.app/standing-desks/issue/HAND-81)

## Context

Cross-agent memory consolidation is controlled by a persisted feature flag.
Core and Swift currently use false when the setting is absent. The feature must
remain optional and be clearly identified as beta in Settings.

## Decision

Retain the cross-agent memory feature flag with a default of false. New
configurations and configurations without an explicit setting keep cross-agent
memory disabled. Preserve an existing explicit opt-in, including one supplied
through supported configuration imports.

Label Cross-agent memory consolidation as Beta in Settings and explain that it
is off by default. Retain its description of sharing and consolidating project
memories between supported agents. The final visual treatment is part of UI review.

Keep feature policy and persistence in `handshake-core`. Swift presents the beta
status and sends flag changes through `CoreClient`, retaining the existing
versioned configuration editing and conflict handling.

The ordinary memory browser remains available when the feature is off. Existing
project-level sharing controls remain conditional on the feature being enabled;
enabling a global feature does not silently change a project's sharing policy.

## Consequences

Default installations do not begin cross-agent memory consolidation. Existing
users who deliberately opted in retain their choice. Validation must cover absent
settings, explicit opt-ins, beta visibility, and the memory browser with sharing
disabled. This decision does not reset a user's saved preferences.

## References

- [Core feature defaults and persistence](../../handshake-core/src/config/experimental.rs)
- [Swift feature decoding](../../macOS/Handshake/Handshake/Core/Protocol/ExperimentalModels.swift)
- [Feature Settings](../../macOS/Handshake/Handshake/Settings/ExperimentalView.swift)
- [Memory sidebar gating](../../macOS/Handshake/Handshake/Memories/MemorySidebar.swift)
- [Project sharing controls](../../macOS/Handshake/Handshake/Memories/MemorySharingControls.swift)
