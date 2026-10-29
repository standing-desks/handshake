# Architecture decision records

This directory is the single canonical home for Handshake's ADRs.
Record product and architecture decisions that affect component boundaries,
saved-state compatibility, feature availability, or shared interaction behavior.
Each numbered record states its status, context, decision, consequences, and
relevant source references. Mark unresolved decisions as Proposed and update
their status when accepted. Supersede accepted records explicitly rather than
silently replacing the decision.

Keep records about the product and its architecture. Put screenshots, prototype
files, test output, and other development artifacts in ignored output directories.
Do not include machine-specific paths or account details.

Keep existing record numbers stable. Allocate new records after the highest
number in this index. Records 0008–0011 retain their original numbers from the
earlier decision series; its other records were removed with the compact-chrome
revert. Historical source inventories retain the paths recorded at that time.

| Record | Status | Decision |
| --- | --- | --- |
| [0001](0001-preserve-native-controls-and-add-accessible-motion.md) | Accepted | Preserve native controls and add accessible layout motion |
| [0002](0002-graduate-tab-management.md) | Accepted | Graduate tab management from the feature-flag catalog |
| [0003](0003-keep-cross-agent-memory-an-opt-in-beta.md) | Accepted | Keep cross-agent memory an opt-in beta |
| [0004](0004-bound-memory-context-and-record-explicit-corrections.md) | Accepted | Bound memory context and record explicit corrections |
| [0005](0005-integrate-kiro-through-native-v3-hooks.md) | Accepted | Integrate Kiro through native V3 hooks and exact conversation profiles |
| [0006](0006-align-and-quiet-the-folder-top-bar.md) | Accepted | Align the folder top bar and use quieter native controls |
| [0008](0008-git-status-default-worktree.md) | Accepted | Limit Git status to each repository's default worktree |
| [0009](0009-handshake-rename-inventory.md) | Accepted | Inventory Handshake rename surfaces and compatibility contracts |
| [0010](0010-project-memory-archive.md) | Accepted | Archive forgotten memories across the project |
| [0011](0011-keep-awake.md) | Accepted | Put Keep Awake in the top-right window toolbar |
| [0012](0012-control-the-embedded-browser-through-core.md) | Accepted | Control the embedded browser through core and a bundled CLI |
