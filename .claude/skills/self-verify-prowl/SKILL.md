---
name: self-verify-prowl
description: Bootstrap-verify Prowl changes by launching a debug app with a dedicated PROWL_CLI_SOCKET and driving it from the current Prowl session. Use after implementing Prowl app, terminal, Active Agents, or CLI changes when Codex should validate behavior end-to-end in a separate Prowl instance, including opening worktrees, creating tabs, running commands or agent sessions, reading panes, and falling back to a single-window screenshot of the debug app when the prowl CLI is insufficient.
---

# Self Verify Prowl

## Overview

Use this skill to validate a Prowl change from inside Prowl itself: start a freshly built debug app, point it at a temporary CLI socket, and use `prowl` from the current session to drive that separate app instance.

Prefer `prowl` CLI operations because they are scriptable and leave useful evidence. When CLI coverage is not enough, fall back to a single-window screenshot of the debug app as a secondary check.

## When To Use

Use this after changes that affect:

- Prowl app behavior that needs a real running GUI instance.
- Terminal tabs, panes, focus, worktrees, or command routing.
- Active Agents detection or roster presentation.
- `ProwlCLI/`, CLI payloads, socket transport, or CLI docs.
- Workflows where one Prowl-hosted agent should verify another Prowl instance.

Do not use this as a replacement for unit tests, `make check`, `make build-app`, or CLI integration tests. It is an end-to-end manual validation layer on top of those checks.

## Preconditions

- Work from the Prowl repository root.
- Preserve unrelated user changes. Do not close or kill the user's normal Prowl app.
- If the CLI changed, build and use the repo CLI, usually `./.build/debug/prowl`.
- If the CLI did not change, an installed `prowl` may be usable, but the repo-built CLI keeps the app/CLI protocol aligned.
- For detailed CLI targeting and recipes, consult the dedicated `prowl-cli` skill first when needed.

## Launch A Separate App

Start the debug app with a dedicated socket so it does not fight the normal installed Prowl instance for the default socket:

```bash
socket="$(mktemp -u /tmp/prowl-self-verify.XXXXXX).sock"
printf '%s\n' "$socket" > /tmp/prowl-self-verify.socket
PROWL_CLI_SOCKET="$socket" make run-app
```

Keep that command running in its own shell session. If plain `make run-app` reports a socket ownership problem, relaunch with a custom `PROWL_CLI_SOCKET`; the installed app may already own the standard socket.

When `PROWL_CLI_SOCKET` is set, CLI auto-launch is disabled. The debug app and every CLI invocation must use the same socket value.

If your shell does not preserve variables across separate command invocations (many agent tool harnesses start a fresh shell each call), `$socket`, `$cli`, `$pane`, and `$tab` will not survive between steps. Persist the socket path as shown above and re-run the setup block below at the top of every later command. The debug app shares the installed app's `~/Library` data, so it loads the real repository list and looks identical to the installed window; never identify the debug instance by appearance. Target it by socket plus pane or tab UUID.

## Reusable Shell Setup

Use this block in each shell command after the debug app has started:

```bash
socket="$(cat /tmp/prowl-self-verify.socket)"
cli="./.build/debug/prowl"

prowl_debug() {
  PROWL_CLI_SOCKET="$socket" "$cli" "$@"
}

debug_pids() {
  for pid in $(pgrep -f "DerivedData/.*/Debug/Prowl.app/Contents/MacOS/ProwlApp"); do
    [ "$(ps -p "$pid" -o comm= 2>/dev/null | sed 's#.*/##')" = "ProwlApp" ] && echo "$pid"
  done
}

for attempt in 1 2 3 4 5 6 7 8 9 10; do
  [ -S "$socket" ] && break
  sleep 1
done
test -S "$socket"
```

Use `prowl_debug ...` for all CLI commands below. Keep `PROWL_CLI_SOCKET` explicit if you inline commands instead of using the helper.

## Drive With Prowl CLI

Use the new CLI when CLI behavior changed:

```bash
make build-cli
cli="./.build/debug/prowl"
```

Then seed the debug app and create a deterministic temporary pane:

```bash
opened="$(prowl_debug open . --json)"
worktree="$(echo "$opened" | jq -r '.data.target.worktree.id')"
created="$(prowl_debug tab create --worktree "$worktree" --json)"
pane="$(echo "$created" | jq -r '.data.target.pane.id')"
tab="$(echo "$created" | jq -r '.data.target.tab.id')"

prowl_debug send --pane "$pane" 'printf "SELF_VERIFY:%s\n" "$PWD"' --capture --timeout 30 --json
prowl_debug read --pane "$pane" --last 80 --wait-stable --json
```

Prefer targeting by pane or tab UUIDs from JSON output. Avoid relying on titles when multiple Prowl instances or similar tabs exist.

Always seed the debug instance with `prowl_debug open . --json` before expecting panes. A fresh debug app can start windowless and return an empty `list`; `open .` creates or focuses a worktree tab that later commands can target. Prefer creating an extra temporary tab for the scenario, then close that tab during cleanup.

`send --timeout` is in seconds (1–300, default 30): the maximum time to wait for the command to finish. The `wait.duration_ms` in the response is how long the command actually took, not the timeout — do not read a small `duration_ms` as the timeout being ignored.

## Run Observable Scenarios

Turn the change into one or more observable scenarios. Prefer small checks that prove the behavior directly:

- For command routing, run a command that prints the cwd, environment, or a unique marker.
- For tab, pane, focus, or worktree behavior, create an isolated tab or pane and inspect `list --json` before and after the action.
- For long-running task behavior, start a controlled command with visible output, then sample the pane with `read`.
- For agent-specific behavior, start a short agent session and use `agents --json` only when the changed behavior involves the Active Agents roster.

Example command scenario:

```bash
prowl_debug send --pane "$pane" \
  'printf "SELF_VERIFY:%s\n" "$PWD"' \
  --capture --timeout 30 --json

prowl_debug read --pane "$pane" --last 80 --wait-stable --json
```

Example long-running scenario:

```bash
prowl_debug send --pane "$pane" \
  'for i in 1 2 3; do echo "SELF_VERIFY_STEP:$i"; sleep 1; done' \
  --no-wait --json

prowl_debug read --pane "$pane" --last 120 --json
```

If the scenario uses another agent, keep it scoped and reversible. Short non-interactive agent tasks can finish before they are sampled; use an interactive session only when the behavior under test requires observing an active retained pane.

## Fallback Checks

`prowl` is the primary control surface, but it cannot verify every visual detail. Use a screenshot when CLI output cannot prove the behavior.

Capture only the debug app's window, not the whole screen. The current Prowl session usually sits in front of the debug instance, so a full-screen `screencapture -x` would show the wrong window. Resolve the debug app's window id from its PID and capture just that window:

```bash
mkdir -p /tmp/prowl-self-verify
debug_pid="$(debug_pids | head -1)"
test -n "$debug_pid"
cat > /tmp/prowl-self-verify/winid.swift <<'SWIFT'
import CoreGraphics
import Foundation
let pid = Int32(CommandLine.arguments[1]) ?? -1
let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
  if let n = w[kCGWindowNumber as String] as? Int { print(n); break }
}
SWIFT
wid="$(swift /tmp/prowl-self-verify/winid.swift "$debug_pid" | head -1)"
test -n "$wid"
screencapture -o -l"$wid" /tmp/prowl-self-verify/prowl-debug-window.png
```

Match on the `Debug/Prowl.app` path so you target the debug instance, never the installed app. `screencapture -o -l<windowid>` grabs just that window without its shadow. Then use `view_image` or another image inspection tool to review it.

Browser or computer-use skills are useful for web and localhost targets, but do not provide reliable control over arbitrary macOS apps. Prefer the Prowl CLI first, then a single-window screenshot for visual gaps.

## Cleanup

Close tabs or panes created for verification:

```bash
prowl_debug tab close --tab "$tab" --force --json
```

Stop the `make run-app` session when validation is done. If you cannot stop that shell directly, terminate only the debug app launched from DerivedData and never the installed `/Applications/Prowl.app`. The Mach-O executable is named `ProwlApp` (not `Prowl`), and a plain `SIGTERM` is enough.

Do not use `pkill -f "<path-pattern>"`: `-f` can also match the shell or helper process carrying that pattern. Use `debug_pids` from the reusable setup block so only processes whose executable basename is `ProwlApp` are signaled:

```bash
for pid in $(debug_pids); do kill "$pid"; done
sleep 2
alive="$(debug_pids | tr '\n' ' ')"
[ -n "$alive" ] && echo "debug still alive:$alive" || echo "debug app stopped"
```

`SIGTERM` does not run the app's normal socket teardown, so the custom socket and its lock can remain. Remove them yourself, along with any screenshots:

```bash
rm -f "$socket" "$socket.lock"
rm -f /tmp/prowl-self-verify.socket
rm -rf /tmp/prowl-self-verify
```

## Report Results

In the final report, include the essentials:

- The socket path used for the debug app.
- The CLI binary used.
- The scenario performed and the concrete observed result.
- Cleanup status.

Add optional details only when they matter: pane or tab UUIDs, agent task state, screenshot path, build/check output, or remaining limitations.
