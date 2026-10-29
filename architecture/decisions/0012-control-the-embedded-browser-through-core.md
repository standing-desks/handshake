# 0012: Control the embedded browser through core

Status: Accepted

## Context

HAND-73 allows an agent in Handshake to navigate, inspect and interact with the
embedded browser while the user can observe and interrupt its work. Browser
tabs retain their native WebKit pages in Swift. Application behavior belongs in
handshake-core, and Swift accesses core through CoreClient.

## Decision

- Browser control is an opt-in beta, disabled by default through
  `experimental.browser_control`. Gate new terminal credentials, native-host
  execution and browser instruction injection on the flag. Disabling it revokes
  every window's authority and pending requests while retaining ordinary browser
  pages. Enabling it requires a new terminal or agent; old credentials never
  become valid again. Regular user-driven browser tabs do not depend on the flag.
- Keep WebKit. Implement a small native driver using public APIs, with the explicit
  guarded beta hover exception below. Do not add
  Chromium, an external browser dependency, a JavaScript REPL, or a claim of
  full Playwright compatibility.
- Core owns a private Unix socket per window runtime, terminal credentials,
  tab ownership, bounded request queues, deadlines and revocation. The bridge
  translates typed host commands and results. CoreClient is Swift's only entry
  point. Swift owns retained pages and executes browser operations on the main actor.
- Bundle a CLI named `handshake`. Terminals and agent harnesses inherit its path
  through `HANDSHAKE_CLI` and receive scoped connection credentials. The CLI
  sends requests to core and returns JSON. A bounded stdio MCP adapter exposes
  the same commands, without shell execution or a JavaScript REPL. App-managed
  Codex and Claude Code launches and resumes receive a uniquely named invocation-only
  MCP entry. Codex forwards the browser credential variables; Claude's inline
  `--mcp-config` references them through environment expansion, keeping tokens out
  of arguments and files. Existing MCP servers remain configured. This supports normal-mode browser use
  without changing shell sandbox settings, approval policy, or global MCP files.
  Claude uses its normal tool permission prompts; registration does not auto-approve tools.
  Managed restrictions on MCP remain authoritative. Other harnesses retain the CLI.
- Supply a compact browser guide through each harness's native instruction
  channel on every app-managed agent launch and resume while enabled, including
  single agents without a role prompt. Preserve existing user instructions and workflow roles.
  Discover command details on demand through CLI help instead of injecting the
  full reference. Do not write project instruction files or install global skills.
  Manually launched agents inside a plain shell inherit the CLI environment but
  do not pass through Handshake's instruction injection.
- An agent opens its own tabs. Commands always use stable tab identifiers;
  they never infer their target from the currently focused window. Another
  terminal cannot operate those tabs. The native host serializes execution.
  Install inspection and console scripts only for agent-created tabs; restored
  tabs return as ordinary user pages without agent authority.
- Provide navigation, compact page snapshots with document-scoped element
  references with bounded retention, native click/fill/hover/dropdown/key input,
  scrolling, screenshots, text/URL/load/element-state waits,
  basic console/error inspection and closing owned tabs. Replaced documents
  and detached elements invalidate references instead of silently retargeting.
  Walk nested same-origin frames and open shadow roots. Bind each reference to
  its issuing document; frame navigation and cross-document adoption invalidate
  old references. Convert frame content coordinates through borders and padding,
  and reject transformed frame geometry instead of guessing. Use native keyboard
  typeahead for dropdown options with a unique initial ASCII letter and verify the
  resulting value; ambiguous options remain manual. Never intercept app menus.
  Reject redirected focus before typing. Restrict modifier keys to movement/deletion.
  App Edit-menu shortcuts (including Command-A and Command-Z) remain unsupported;
  `fill` replaces ordinary fields directly. Hover uses the optional WebKit
  `_simulateMouseMove:` testing entry point, guarded by selector availability and
  a key window. Ordinary AppKit mouse-move delivery does not produce synthetic
  hover reliably. Return an explicit unsupported error when the entry point is
  absent; keep this compatibility risk inside the beta flag.
- Display the controlling terminal and Stop / Take over in the browser. Taking
  over revokes that terminal's authority, cancels pending work, stops loading,
  and retains the page for the user. Already submitted website actions cannot
  be undone. A new terminal is required to grant control again. Closing a
  terminal revokes its authority too. Authority does not survive app restart.
- Agent sandbox permissions remain separate from browser authority. A sandbox
  may deny local Unix-socket connections even though CLI help works. Report
  this as `transport_permission_denied` and request approval for the exact CLI
  command through the harness's normal permission flow. Do not automatically
  enable YOLO, change global permissions, or add a fallback that circumvents
  the sandbox. A denied or unavailable approval ends the operation; a revoked
  Handshake credential remains revoked even after sandbox approval.
- Use bounded asynchronous WebKit calls and native input directed at the page,
  not global desktop pointer automation. Require a visible page for input.
  Treat page text and console output as untrusted data, not instructions.
- Current limits are explicit: HTTP(S), same-origin frames, open shadow roots,
  ordinary text fields and single-select dropdowns, editing keys, viewport screenshots,
  and manual handling of passwords, dialogs and uploads. Cross-origin or transformed
  frames, closed shadow roots, rich editors,
  cookie export, network interception and annotations are separate work.

## Consequences

Agents with shell tools can share one browser interface without per-harness MCP
setup. The user sees the actual page. Core tests exercise ownership, cancellation
and socket framing independently of macOS. Native tests must prove trusted input,
reference invalidation, screenshot capture and the CLI-to-page-to-takeover flow.
The endpoint is a local same-user capability, not a sandbox against malicious
processes already able to inspect another process owned by that user.

## References

- [HAND-73](https://linear.app/standing-desks/issue/HAND-73/add-browser-control-so-agents-can-drive-twines-browser)
- [cmux browser automation](https://cmux.com/docs/browser-automation)
- [cmux WebKit driver architecture](https://github.com/manaflow-ai/cmux/blob/v0.65.2.2/docs/browser-repl/README.md)
- [ChatGPT built-in browser](https://learn.chatgpt.com/docs/browser)
- [cmux browser skill](https://github.com/manaflow-ai/cmux/blob/aa4dcd453ce9a2ce5baa66c0863ef8d5758a4350/skills/cmux-browser/SKILL.md)
- [cmux native computer-use integration](https://cmux.com/docs/computer-use)
- [Claude Code MCP configuration](https://code.claude.com/docs/en/mcp)
- [Claude Code invocation flags](https://code.claude.com/docs/en/cli-reference)
- [Codex native MCP configuration](https://learn.chatgpt.com/docs/extend/mcp)
- [WebKit select keyboard behavior](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/html/HTMLSelectElement.cpp)
- [cmux native mouse delivery](https://github.com/manaflow-ai/cmux/blob/main/Packages/macOS/CmuxBrowser/Sources/CmuxBrowser/WebView/CmuxWebView+AutomationInput.swift)
