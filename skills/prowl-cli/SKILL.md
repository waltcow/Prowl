---
name: prowl-cli
description: Use the Prowl CLI to inspect or control a running Prowl app, especially when a user asks to read from, coordinate, focus, send text to, or send keys to Prowl worktrees, tabs, panes, or sibling agent sessions.
---

# Prowl CLI

Use `prowl` when the user explicitly wants to inspect or control Prowl: reading another pane, checking sibling agent progress, focusing a tab/pane, opening a repo/path in Prowl, or sending text/keys to a Prowl terminal pane.

Do not use it just because the current shell happens to be inside a Prowl repository. It is a remote-control interface for the running Prowl GUI app.

## ⚠️ You are probably running *inside* one of these panes

If your own session was launched from a Prowl terminal, then **one of the panes `prowl list` returns is you.** `prowl list` does not exclude the caller. Acting on your own pane is self-harm: `prowl key --pane <self> esc` (or `ctrl-c`) interrupts or kills *your own* current request, and `send` injects into your own prompt.

**Before any `send`, `key`, or `focus`, identify your own pane and never target it:**

```bash
# Your own pane = the focused one (and its cwd matches your $PWD).
echo "$PWD"
prowl list --json | jq -r '.data.items[] | select(.pane.focused == true) | .pane.id'
```

Danger signs that a pane you are reading **is yourself**: its content is your own conversation transcript, or it shows a prompt identical to the one you are currently executing. A pane's *tab title* can say anything (e.g. "UniWebView") while its real `cwd` is somewhere else — trust `cwd` and the focused flag, not the title.

To run an agent "over in project X", do **not** reuse a same-looking existing pane. Open a fresh one and confirm its id differs from your own:

```bash
prowl open /path/to/project-X --json   # returns a brand-new pane id
# verify: the returned .data.target.pane.id != your own focused pane id
```

## Core Workflow

Discover panes first — and immediately mark which pane is yourself (see the warning above) so you never send/key/focus it:

```bash
prowl list --json
```

Select explicit UUIDs from the JSON. Prefer `--pane <pane-id>` for `read`, `send`, `key`, and `focus`.

Read a pane:

```bash
prowl read --pane <pane-id> --last 80 --json
```

Send text without waiting:

```bash
prowl send --pane <pane-id> 'command here' --no-wait --json
```

Send and capture command output when machine verification matters:

```bash
prowl send --pane <pane-id> 'command here' --capture --timeout 30 --json
```

Send a key (double-check `<pane-id>` is **not your own** — `esc`/`ctrl-c` sent to yourself aborts your current request):

```bash
prowl key --pane <pane-id> enter --json
prowl key --pane <pane-id> ctrl-c --json
```

Focus a pane:

```bash
prowl focus --pane <pane-id> --json
```

Open a path in Prowl:

```bash
prowl open /path/to/repo --json
```

## Finding Pane IDs

By worktree path or repository directory name:

```bash
prowl list --json | jq -r '
  .data.items[]
  | select(.worktree.path | rtrimstr("/") | endswith("/Prowl"))
  | .pane.id
'
```

By selected/focused pane (this is almost always **yourself** — use it to exclude, not to target):

```bash
prowl list --json | jq -r '.data.items[] | select(.pane.focused == true) | .pane.id'
```

By tab or pane title substring:

```bash
prowl list --json | jq -r '
  .data.items[]
  | select((.tab.title + " " + .pane.title) | contains("ProwlCLI"))
  | .pane.id
'
```

For a compact human scan:

```bash
prowl list --no-color
```

## Waiting and Completion

`prowl send` waits for shell integration by default. If the target pane does not report command completion, it can return `WAIT_TIMEOUT`.

Default to `--no-wait` for simple input delivery. Use `--capture --timeout <seconds>` when you need an exit code, duration, and captured output.

`task.status` from `prowl list --json` is useful for coordinating sibling sessions:

- `running`: the pane/worktree is still busy.
- `idle`: it is likely ready for the next step.

Polling pattern:

```bash
prowl list --json | jq -r '
  .data.items[]
  | select(.pane.id == "<pane-id>")
  | .task.status
'
```

## Quoting

Protect commands from the local shell when they should expand inside the target pane:

```bash
prowl send --pane <pane-id> 'printf "PWD:%s\n" "$PWD"' --no-wait
```

Avoid outer double quotes around payloads containing `$PWD`, `$VAR`, backticks, or command substitutions unless local expansion is intended.

For multiline or generated input, pipe stdin:

```bash
printf '%s\n' 'echo first' 'echo second' | prowl send --pane <pane-id> --no-wait --json
```

## Error Handling

- `APP_NOT_RUNNING`: Prowl is not running, or its CLI service is unavailable. Ask the user before restarting Prowl.
- `TARGET_NOT_FOUND` / `TARGET_NOT_UNIQUE`: run `prowl list --json` again and resolve an explicit pane UUID.
- `WAIT_TIMEOUT`: retry with `--no-wait`, or use a pane with shell integration for `--capture`.
- `UNSUPPORTED_KEY`: inspect `prowl key --help`; use canonical tokens such as `enter`, `esc`, `tab`, `up`, `down`, `ctrl-c`, `cmd-k`, or `f1`.

## Notes

- JSON output is the automation surface; text output is for humans.
- `-t/--target` auto-resolves pane UUID, tab UUID, or worktree id/name/path, but explicit `--pane` is safer for automation.
- Future Prowl versions may add commands such as `prowl action`, `prowl tab`, or `prowl pane`. Check `prowl --help` before using commands not listed here.
