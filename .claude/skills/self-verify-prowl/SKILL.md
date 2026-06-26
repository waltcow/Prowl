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

## First Step — Read the prowl-cli Skill

**Before writing any `prowl` command, load and read the `prowl-cli` skill.** This is not optional. `prowl-cli` is the authoritative reference for JSON field names, targeting rules, quoting, argument semantics, error codes, and common pitfalls. This skill covers the self-verify workflow; `prowl-cli` covers how to use `prowl` correctly. Do not guess field names — get them from `prowl-cli`.

Concretely: invoke the `prowl-cli` skill (or read its SKILL.md) before proceeding to the Launch step. If you skip this, you will likely use wrong JSON paths, miss quoting rules, or hit avoidable pitfalls.

## Preconditions

- Work from the Prowl repository root.
- Preserve unrelated user changes. Do not close or kill the user's normal Prowl app.
- If the CLI changed, build and use the repo CLI, usually `./.build/debug/prowl`.
- If the CLI did not change, an installed `prowl` may be usable, but the repo-built CLI keeps the app/CLI protocol aligned.

## Launch A Separate App

The debug app uses a fixed socket at `/tmp/prowl-self-verify.sock`. This path is stable across shell invocations, so every step can reference it directly without intermediate files or re-sourcing.

Clean up any stale socket from a previous run, then start the debug app in a persistent shell session:

```bash
rm -f /tmp/prowl-self-verify.sock /tmp/prowl-self-verify.sock.lock
mkdir -p /tmp/prowl-self-verify
PROWL_CLI_SOCKET=/tmp/prowl-self-verify.sock make run-app >/tmp/prowl-self-verify/run-app.log 2>&1
```

Keep that command running in its own shell or PTY session for the whole validation run.

Do not launch the built `ProwlApp` binary directly in the background from an agent shell. Once that shell exits, the app can exit and leave a stale socket behind.

If plain `make run-app` reports a socket ownership problem, relaunch with the custom `PROWL_CLI_SOCKET`; the installed app may already own the standard socket.

If the socket appears but `prowl_debug list --json` returns `APP_NOT_RUNNING`, the app likely exited and left a stale socket/lock behind. Remove both socket files, confirm no debug `ProwlApp` PID is still alive, then relaunch with `PROWL_CLI_SOCKET=/tmp/prowl-self-verify.sock make run-app` in a persistent shell session. If it returns `SOCKET_PERMISSION_DENIED`, the agent sandbox cannot connect to that socket path; allowlist the path or rerun the CLI outside that sandbox.

When `PROWL_CLI_SOCKET` is set, CLI auto-launch is disabled. The debug app and every CLI invocation must use the same socket value.

The debug app shares the installed app's `~/Library` data, so it loads the real repository list and looks identical to the installed window; never identify the debug instance by appearance. Target it by socket plus pane or tab UUID.

## Use The Run-App Log

The `make run-app` log is the third verification surface, alongside `prowl read` and screenshots. Capture it to `/tmp/prowl-self-verify/run-app.log` as shown above instead of streaming the full output into the agent context.

This is especially useful when you add your own logging during development or debugging. The recommended workflow is:

1. Add `SupaLogger` calls in the code you are changing to emit markers you can search for later.
2. Rebuild and relaunch the debug app so the new logs take effect.
3. Before running a scenario, record the current log line count. After the scenario, inspect only the new lines, filtering for the markers you added:

```bash
log=/tmp/prowl-self-verify/run-app.log
before="$(wc -l <"$log" | tr -d ' ')"

# Run prowl_debug open/tab/send/read operations here.

sleep 3
after="$(wc -l <"$log" | tr -d ' ')"
sed -n "$((before + 1)),${after}p" "$log" \
  | rg "YourMarker|error|warning"
```

Replace `YourMarker` with whatever log prefix or keyword you introduced in step 1. Do not hard-code a fixed set of log patterns — choose search terms that match the specific behavior you are verifying.

Logs can arrive a few seconds after the CLI command returns, so wait briefly and re-check before concluding an event is missing.

Do not treat the log as the primary proof of terminal contents or CLI response shape. Use `prowl read` for terminal text, ordinary `jq` for CLI JSON, and screenshots for visual gaps.

## Reusable Shell Setup

Available script:

- `scripts/helpers.sh` — Source-only helpers for the dedicated socket, tolerant JSON parsing, debug PID lookup, health checks, and PID-scoped screenshots.

Use the bundled helper script instead of re-pasting shell functions. Source it after the debug app has started, then run its health check before driving the app:

```bash
. .claude/skills/self-verify-prowl/scripts/helpers.sh
wait_for_prowl_debug
```

For each later shell command, source the helper and rerun the health check before driving the app:

```bash
. .claude/skills/self-verify-prowl/scripts/helpers.sh
wait_for_prowl_debug
```

Use `prowl_debug ...` and `debug_window_id` from `scripts/helpers.sh` for the commands below. Keep `PROWL_CLI_SOCKET` explicit if you inline commands instead of using the helper.

Parse `--json` output with ordinary `jq`. Do not pipe shell variables through `echo "$json" | jq`: zsh can interpret JSON escape sequences such as `\u001B` and turn them back into raw control characters. Use direct CLI pipes, files, or `printf '%s\n' "$json" | jq`.

If `jq` reports invalid control characters while parsing direct CLI stdout or a captured file, treat it as a CLI regression rather than working around it in this skill.

## Drive With Prowl CLI

Use the new CLI when CLI behavior changed:

```bash
make build-cli
cli="./.build/debug/prowl"
```

Then seed the debug app and create a deterministic temporary pane:

```bash
opened="$(prowl_debug open . --json)"
worktree="$(printf '%s\n' "$opened" | jq -r '.data.target.worktree.id')"
created="$(prowl_debug tab create --worktree "$worktree" --json)"
pane="$(printf '%s\n' "$created" | jq -r '.data.target.pane.id')"
tab="$(printf '%s\n' "$created" | jq -r '.data.target.tab.id')"

prowl_debug send --pane "$pane" 'printf "SELF_VERIFY:%s\n" "$PWD"' --capture --timeout 30 --json \
  | jq -r '.data.capture.text'
prowl_debug read --pane "$pane" --last 80 --wait-stable --json \
  | jq -r '.data.text'
```

Prefer targeting by pane or tab UUIDs from JSON output. Avoid relying on titles when multiple Prowl instances or similar tabs exist.

Key JSON fields (see `prowl-cli` skill for the full reference):

- `read --json` → terminal text is `.data.text`, not `.content` or `.output`.
- `send --capture --json` → captured output is `.data.capture.text`; exit code is `.data.wait.exit_code`.
- `list --json` → pane list is `.data.items[]`, not `.worktrees[]`; each item has `.pane.id`, `.tab.id`, `.worktree.id`, `.task.status`.

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
result="$(prowl_debug send --pane "$pane" \
  'printf "SELF_VERIFY:%s\n" "$PWD"' \
  --capture --timeout 30 --json)"
printf '%s\n' "$result" | jq -r '.data.capture.text'
printf '%s\n' "$result" | jq -r '.data.wait.exit_code'

prowl_debug read --pane "$pane" --last 80 --wait-stable --json \
  | jq -r '.data.text'
```

Example long-running scenario:

```bash
prowl_debug send --pane "$pane" \
  'for i in 1 2 3; do echo "SELF_VERIFY_STEP:$i"; sleep 1; done' \
  --no-wait --json

prowl_debug read --pane "$pane" --last 120 --json \
  | jq -r '.data.text'
```

If the scenario uses another agent, keep it scoped and reversible. Short non-interactive agent tasks can finish before they are sampled; use an interactive session only when the behavior under test requires observing an active retained pane.

## Fallback Checks

`prowl` is the primary control surface, but it cannot verify every visual detail. Use a screenshot when CLI output cannot prove the behavior.

Capture only the debug app's window, not the whole screen. The current Prowl session usually sits in front of the debug instance, so a full-screen `screencapture -x` would show the wrong window. Use `debug_window_id` from the reusable setup block to resolve a PID-scoped window id:

```bash
. .claude/skills/self-verify-prowl/scripts/helpers.sh
wid="$(debug_window_id)"
test -n "$wid"
screencapture -o -l"$wid" /tmp/prowl-self-verify/prowl-debug-window.png
```

`debug_window_id` compiles its tiny CoreGraphics helper on first screenshot use and reuses it for later screenshots in the same run. `screencapture -o -l<windowid>` grabs just that window without its shadow. Then use `view_image` or another image inspection tool to review it.

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
rm -f /tmp/prowl-self-verify.sock /tmp/prowl-self-verify.sock.lock
rm -rf /tmp/prowl-self-verify
```

## Report Results

In the final report, include the essentials:

- The CLI binary used (repo-built or installed).
- The scenario performed and the concrete observed result.
- Cleanup status.

Add optional details only when they matter: pane or tab UUIDs, agent task state, screenshot path, build/check output, or remaining limitations.
