# ADR 0011: Put Keep Awake in the top-right window toolbar

- Recorded: 2026-10-27
- Status: Accepted
- Issue: [HAND-70](https://linear.app/standing-desks/issue/HAND-70/add-a-caffeinate-button-that-keeps-the-mac-awake)

## Decision

Place a native Keep Awake button with an explicit On/Off state at the top right
of each window, including the start page. The user moved the approved prototype
from the bottom status bar to the top right to match the familiar placement of
Caffeine and Amphetamine controls. This is a window toolbar control; it does not
add a macOS menu-bar item.
Use native high visibility priority on macOS 26.1 and later so the control stays
available when the folder title overflows. macOS 26.0 uses standard toolbar overflow.
Bound the folder title’s layout width so it leaves room for toolbar actions; retain its full-path tooltip.

Keep Awake is one app-wide, temporary setting. It starts Off and remains On across
folder changes, tasks, and window closures until disabled or the app quits. Core
owns one `caffeinate -disu -w <app-pid>` process; the bridge only adapts its API and
Swift presents the live state. Turning it Off or quitting stops and reaps the
child. Watching the app PID also releases assertions after an unexpected exit.

## Consequences

No saved preference, per-agent setting, extra macOS permission, or privileged
helper is required. Polling detects an unexpected child exit and returns the UI
to Off. The command prevents idle system and display sleep; it does not override
lid-close or explicit Sleep. The `-s` assertion applies only on AC power.
