<h1 align="center"><img src="docs/assets/handshake-readme-lockup.svg" alt="Handshake" width="236" height="48"></h1>

<p align="center">A native macOS workspace for coordinating coding agents.</p>

<p align="center">
  <a href="https://github.com/standing-desks/handshake/releases/latest"><img src="https://img.shields.io/github/v/release/standing-desks/handshake?color=8250df" alt="Latest release"></a>
  <a href="https://github.com/standing-desks/handshake/releases"><img src="https://img.shields.io/github/downloads/standing-desks/handshake/total?color=orange" alt="Total downloads across all release assets"></a>
  <a href="https://github.com/standing-desks/handshake/actions/workflows/ci.yml"><img src="https://github.com/standing-desks/handshake/actions/workflows/ci.yml/badge.svg?branch=main&amp;event=push" alt="CI status on main"></a>
  <a href="#install"><img src="https://img.shields.io/badge/macOS-26%2B-0969da" alt="macOS 26 or later"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/standing-desks/handshake" alt="MIT license"></a>
</p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="https://standing-desks.github.io/handshake/documentation/guide/">User guide</a> ·
  <a href="#contributing">Contributing</a>
</p>

Handshake is the terminal-first collaboration layer for AI coding agents.
Bring agents together through controlled workflows, visual traces, and cross-agent memory.

## Install

Handshake requires **macOS 26 or later** on **Apple Silicon**.

Install it with [Homebrew](https://brew.sh):

```sh
brew install --cask standing-desks/tap/handshake
```

Then open Handshake from Applications.

To install manually instead, download the `.dmg` from the
[latest release](https://github.com/standing-desks/handshake/releases/latest), open it,
and drag **Handshake** onto **Applications**.

To update a manual install, see the
[install notes](https://standing-desks.github.io/handshake/documentation/guide/#install).

Agent workflows also need at least one [supported harness](#supported-harnesses)
installed and signed in. Terminal workflows need nothing else.

## Upgrade from Twine

Quit Twine and Handshake before upgrading. New installs use
`brew install --cask standing-desks/tap/handshake`. For an existing Homebrew
install, run these commands after the tap's rename migration is available:

```sh
brew trust --cask standing-desks/tap/handshake
brew update
brew upgrade --cask standing-desks/tap/handshake
```

Homebrew 6 and newer require explicit trust for the renamed cask; trust in an
old name does not follow the rename. Omit the trust command on older Homebrew
versions that do not provide it. See [Homebrew's tap trust guidance](https://docs.brew.sh/Tap-Trust).
Historical `twine-app` and `twine-ade` casks map to `handshake`. Existing
`twineproject/tap` users should use `twineproject/tap/handshake` in both the trust
and upgrade commands; they do not need to switch taps or install a second copy.

For a manual install, copy **Handshake.app** from the new DMG into
**Applications**. Replace an existing Handshake copy, or move the old
**Twine.app** to Trash once Handshake is in place. Keep only one app to launch.
Normal app removal or `brew uninstall --cask handshake` preserves saved data;
do not use `--zap` if you want to keep it.

On the first production launch, Handshake adopts
`~/Library/Application Support/Twine/` into the new sibling `Handshake/` root,
including sessions, transcripts, trace details, attachments, and workflow
layouts. It also adopts the config tree from `$XDG_CONFIG_HOME/twine/` to
`$XDG_CONFIG_HOME/handshake/` (default `~/.config/`). Imports, custom workflows,
and themes move together. Existing Handshake roots take precedence and are
never overwritten. Preference domains stay the same, preserving launch
choices, models, and zoom.

The legacy data and config roots are retained as recovery sources. Quit both
apps before recovery. Move the new Handshake root aside rather than deleting
it, then use the old app with its retained Twine data, or relaunch Handshake to
retry migration. For copied roots, changes made after migration are not copied
back into Twine. Symlink-managed config roots and linked files keep sharing
their original targets, so edits are visible through both names; keep a separate
backup of those target files if you need to roll back their contents.
If migration reports that the old data is in use, quit the old app and retry.

Explicit `HANDSHAKE_DATA_DIRECTORY` and `HANDSHAKE_CONFIG_PATH` overrides skip
production/default-root migration. `HANDSHAKE_PREFERENCES_SUITE` and
`HANDSHAKE_HARNESS_PATH` select the preference store and harness search path.
Each of these inputs takes precedence over its corresponding `TWINE_*`
fallback. The config-path override must be absolute; an invalid present new
value does not fall back to the old name. Existing `twine_light`/`twine_dark`
theme selections, imports, and customized files remain supported, including
the existing Silica theme compatibility. Debug builds, previews, and tests use
isolated data and never select production data migration.

## Quick start

This takes about a minute and needs no agent harness.

1. Open Handshake and choose **Open Folder…** (⌘O). Pick any project folder.
2. Create a session. A session groups the work for one task.
3. Add a workflow in a new tab and choose **Terminal**.
4. Run a command in the terminal, for example `git status`.

You should see the command's output in the terminal and one step for that
command in the Traces panel. Selecting the step jumps to its output.

To run your first agent workflow, add another tab and choose **Adversarial**.
Pick a harness for the implementer and for the reviewer, start the workflow, and
type a task in the implementer's terminal. When the implementer submits its
completion, the reviewer's terminal receives the work and either approves it or
sends changes back.

## Usage

A **session** is a named body of work in a folder. Each top-level tab in a
session is a **workflow**. Select a built-in workflow or create your own agent graph:

| Workflow | How it works |
| --- | --- |
| Terminal | A plain shell, with optional split panes. |
| Single agent | One interactive coding agent. |
| Adversarial | An implementer does the task; a reviewer approves it or requests changes. |
| Coordinator | A planner sends a shared plan to two workers. A coordinator waits for both results and checks their work. |
| Custom | Your own graph of agents and event links. Run agents in parallel, stream pieces, review results, or compare times. |

Click **+**, then **Create your own**, to open the native graph editor in the new
tab. Saved workflows are TOML files in `$XDG_CONFIG_HOME/handshake/workflows`
(default `~/.config/handshake/workflows`). Copy these files to share workflows or keep them
in version control. Agent instructions use native harness instruction channels;
setup does not start agent work.

Enable **Agent browser control (Beta)** in **Settings → Experimental** to try it;
it is off by default. Start a new terminal or agent after enabling.
Agents started or resumed through Handshake then receive browser instructions automatically.
They can control the embedded browser from a Handshake terminal through
`"$HANDSHAKE_CLI" browser --help`. Use `browser open URL` to create an owned tab,
then `browser --tab ID snapshot` to inspect it. Commands support native input,
hover, dropdown selection, editing-key modifiers, scrolling, screenshots,
text/URL/load/element waits and console inspection. Snapshots include nested
same-origin frames and open shadow roots. Native dropdown selection requires a
unique initial ASCII letter; other options require manual selection. Hover requires
a focused browser window and compatible WebKit. The browser shows
which terminal controls it; **Stop / Take over** cancels pending commands and
revokes that terminal's control while leaving the page open. Passwords, dialogs
and uploads require the user. See [the browser-control decision](architecture/decisions/0012-control-the-embedded-browser-through-core.md)
for the supported scope. Codex and Claude Code receive a session-local MCP browser tool. Their shell
sandbox and permission settings stay unchanged. Other sandboxed agents may need approval to run the browser
CLI outside their sandbox so it can connect to Handshake's local socket. Approve
the specific command through the agent's permission prompt; disabling the whole
sandbox is not required. If approval is unavailable, use a plain Handshake terminal.

Common tasks, each covered in the
[user guide](https://standing-desks.github.io/handshake/documentation/guide/):

- **Advance a workflow yourself.** Use **Mark done…** to submit a completion,
  review decision, or assignment on an agent's behalf. See
  [agent workflows](https://standing-desks.github.io/handshake/documentation/guide/#agent-workflows).
- **Split a terminal** into up to four panes, and paste images or drop files
  into a pane as paths. See
  [terminal panes](https://standing-desks.github.io/handshake/documentation/guide/#terminal-panes).
- **Browse and edit files** in the open folder with syntax highlighting. See
  [files](https://standing-desks.github.io/handshake/documentation/guide/#files).
- **Change the terminal font** in **Handshake → Settings…** (⌘,), which edits
  `~/.config/handshake/config.toml` and applies changes on save. See
  [configuration](https://standing-desks.github.io/handshake/documentation/guide/#configuration).

  ```toml
  [terminal]
  font_family = "JetBrains Mono"
  font_size = 13.0
  ```

- **Inspect recorded agent activity** in **Traces → In Depth**. Overview shows
  activity counts and an **Inspect activity** action. LLM calls include public
  responses/summaries, model and usage details when the harness supplies them;
  missing timings or request bodies remain marked as unrecorded. **Show full
  details** opens complete saved inputs and results.
  The storage control shows usage, pins a step, and clears completed, unpinned
  details. Handshake keeps compact metadata in SQLite and deduplicates large details
  in adjacent files. Active steps and pinned details can exceed the cache budget.
  Native harness files remain untouched.

  ```toml
  [traces]
  detail_budget_mb = 512
  retention_days = 90 # Closed, unpinned workflows; 0 disables age expiry.
  ```

  Saved Codex, Claude Code, Pi, and OMP conversations can recover activity for
  their linked steps. Recovery uses native IDs or an unambiguous prompt/time
  match within the same conversation. It cannot recover data absent from both
  the observer and native history. OpenCode and Antigravity use live observers.

### Supported harnesses

A **harness** is the external agent CLI that fills a role. Handshake finds each one
by its command on your shell's `PATH`:

| Harness | Command | Prompt and tool detail in Traces |
| --- | --- | --- |
| Codex | `codex` | Yes |
| Claude Code | `claude` | Yes |
| pi | `pi` | Yes |
| OMP | `omp` | Yes |
| Antigravity | `agy` | Yes; model invocation details where exposed |
| OpenCode v2 | `opencode` | Yes |
| Kiro CLI V3 | `kiro-cli` | Yes; completed tool observations without inferred call durations |

Install and authenticate harnesses separately. Model choices come from each
harness's own CLI, and provider access and usage charges follow your harness
configuration. Handshake never edits your harness config files.

For Kiro, run `kiro-cli login` first. Handshake supplies a temporary named profile
for its hooks and workflow role instructions and restores that profile identity
when resuming a captured conversation. Existing Kiro profiles and settings remain
in place. Kiro's workspace-trust prompt appears when its native policy requires it.

## Project status

Handshake is in **early development**. It is usable day to day, but features,
integrations, and saved formats can change between releases, and there are no
stability guarantees yet. The [changelog](CHANGELOG.md) lists what changed in
each release.

Known limitations:

- Agents run directly in the open folder. Handshake does not create worktrees or
  sandboxes, and file ownership between parallel workers is advisory.
- Handshake is an interactive desktop app. It does not run workflows unattended or
  headless.
- Harness support depends on CLI versions, and a harness update can break an
  integration until Handshake catches up.
- Tracing is best effort. Recorded terminal output is capped at 64 MiB per
  terminal and 512 MiB overall, so older output can expire.
- Resuming a conversation depends on the harness recording a session handle.

## Contributing

[Contributing Guide](CONTRIBUTING.md) · [Developer Certificate of Origin](DCO)

Bug reports and feedback on real workflows are welcome in
[GitHub Issues](https://github.com/standing-desks/handshake/issues). Include your macOS,
Handshake, and harness versions, what you expected, and what happened. For larger
changes, open an issue to discuss the idea before you start. Changes reach
`main` through pull requests.

### Build from source

You will need:

- **Xcode 27.0**, selected as the active developer toolchain. Command Line Tools
  alone are not enough.
- The **Xcode Metal Toolchain**: `xcodebuild -downloadComponent MetalToolchain`.
- **Stable Rust**, installed through [rustup](https://rustup.rs).

```sh
git clone https://github.com/standing-desks/handshake.git handshake-checkout
cd handshake-checkout
make debug
open out/debug/Build/Products/Debug/Handshake.app
```

Run these commands from the checkout root, regardless of its directory name.
Debug builds keep their data in `out/runtime/debug/`, separate from an installed
copy of Handshake.

### Check your changes

```sh
make fmt      # format the library and the app
make check    # lint and unit-test the library and the app
make          # list every target
```

`make ui-test` runs the UI suite and takes over the desktop while it runs.
The authenticated Codex browser check is opt-in: set `TEST_RUNNER_HANDSHAKE_LIVE_CODEX`
to the path of a logged-in Codex executable and run
`make ui-test ONLY=testBrowserCodexMCPWorksWithNormalSandbox`. It uses Codex's
workspace sandbox with automatic approval review for the local fixture task.
For Claude Code, set `TEST_RUNNER_HANDSHAKE_LIVE_CLAUDE` to its authenticated
executable and run `make ui-test ONLY=testBrowserClaudeMCPControlsNativePage`.
This test allows only the fixture's browser MCP tool through Claude's normal
permission configuration; production launches do not auto-approve tools.

### Find your way around

| Path | Contents |
| --- | --- |
| `macOS/` | The SwiftUI and AppKit front end. |
| `handshake-core/` | The Rust application library that owns behavior and saved state. |
| `handshake-bridge/` | The C ABI adapter between the two. |
| `docs/` | Source for the [website and guides](https://standing-desks.github.io/handshake/). |

The [development guide](https://standing-desks.github.io/handshake/documentation/development/)
covers setup, harness integration, and releases.
[CONTEXT.md](CONTEXT.md) defines the terms used in the code and UI, and
[AGENTS.md](AGENTS.md) holds the repository conventions.

## Security

Please report vulnerabilities privately through
[GitHub security advisories](https://github.com/standing-desks/handshake/security/advisories/new)
instead of a public issue.

## Acknowledgments

Thank you to [AI Tinkerers Seattle](https://seattle.aitinkerers.org/) for the
opportunity to demo and premiere Twine. Handshake's terminal emulation uses
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).

## License

Handshake is available under the [MIT License](LICENSE).
