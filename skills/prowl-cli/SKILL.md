---
name: prowl-cli
description: >-
  Use the Prowl CLI (`prowl`) to inspect or control a running Prowl GUI app and the agent sessions it hosts. Prowl runs several coding agents in parallel, each in its own pane/tab/worktree, so reach for this whenever the user wants to act on a pane other than the current one — check on, coordinate, read from, focus, send text or keys to, open, or close another pane, tab, worktree, split, window, or sibling/neighboring agent. Covers colloquial framings that never say "prowl": "check what the agent in my other window is doing", "are any of my agents running side by side still working or idle?", "tell the agent in my left split to rerun the tests", "send npm run build to the build tab and grab the output", "open ~/proj in a fresh tab", "close that scratch tab I left open". Not for ordinary editing or building inside the Prowl source repo, and not for how-to questions about Prowl's settings, preferences, or keybindings — only when the task is to actually drive panes in the live Prowl app.
---

# Prowl CLI

Use `prowl` only when the task is to inspect or control the running Prowl GUI app: read panes, check sibling agents, focus a pane, open a repo/path in Prowl, send text, or send keys. Do not use it merely because the current shell is inside the Prowl repo.

## Safe Default Workflow

Always resolve a concrete pane UUID before `read`, `send`, `key`, `focus`, or destructive close commands.

```bash
prowl list --json
```

Pick the target by `pane.id`, `tab.id`, `worktree.id`, `worktree.path`, `pane.cwd`, and `pane.focused`. Do not trust tab titles: they are free-form and can lag or lie.

If your session was launched from a Prowl pane, the focused pane is often you. Treat focused pane IDs as something to identify and avoid unless you intentionally want to operate on yourself.

```bash
self_pane="$(prowl list --json | jq -r '.data.items[] | select(.pane.focused == true) | .pane.id')"
```

Use explicit `--pane`:

```bash
prowl read --pane "$pane" --last 80 --wait-stable --json
prowl send --pane "$pane" 'printf "PWD:%s\n" "$PWD"' --capture --timeout 30 --json
prowl focus --pane "$pane" --json
prowl key --pane "$pane" enter --json
```

## Common Recipes

Create a fresh tab for a listed worktree, then verify it is not yourself:

```bash
project="/path/to/project"
worktree="$(prowl list --json | jq -r --arg project "$project" '
  .data.items[]
  | select((.worktree.path | rtrimstr("/")) == ($project | rtrimstr("/")))
  | .worktree.id
' | head -n 1)"
pane="$(prowl tab create --worktree "$worktree" --json | jq -r '.data.target.pane.id')"
test "$pane" != "$self_pane"
```

Prefer a `worktree.id` or `worktree.name` returned by `prowl list` over a hand-typed path; list preserves normalization such as trailing slashes. Use `--path` only for the new tab's working directory inside the selected worktree.

`prowl open /path` opens or focuses a matching project/path and may create a tab when needed. It is not guaranteed to create a new pane. Use `prowl tab create` for deterministic new terminal sessions.

Run a command and capture its result:

```bash
prowl send --pane "$pane" 'git status --short' --capture --timeout 30 --json
```

Deliver input without waiting:

```bash
prowl send --pane "$pane" 'long-running command' --no-wait --json
```

Pre-fill text, then submit it later:

```bash
prowl send --pane "$pane" 'echo ready' --no-enter --no-wait --json
prowl key --pane "$pane" enter --json
```

Use this pattern only for a pane you have positively identified. If `$pane` is your own pane, `key enter` submits text into your current session.

Send multiline input from stdin:

```bash
printf '%s\n' 'echo first' 'echo second' | prowl send --pane "$pane" --capture --timeout 30 --json
```

Close a temporary tab/pane when done:

```bash
prowl pane close --pane "$pane" --json
prowl tab close --tab "$tab" --json
```

`tab close` and `pane close` require an explicit `--tab`, `--pane`, `--worktree`, or `--target`; they intentionally do not default to the currently focused pane. For automation-created tabs, prefer the `tab.id` or `pane.id` returned by `tab create`. If the target has protected agent work or a long-running command, Prowl may ask for GUI confirmation. Use `--force` only after you have positively identified the target:

```bash
prowl pane close --pane "$pane" --force --json
```

## Reading Agent Output

`task.status` is useful for coordination but is not enough to prove the screen finished rendering. `idle` can arrive before a TUI has painted its final response.

Prefer `read --wait-stable` for screen snapshots:

```bash
prowl read --pane "$pane" --last 200 --wait-stable --json
```

Most of the time `--wait-stable` alone is enough — it blocks until the screen stops changing. Only poll `task.status` first when you specifically need to wait for an agent to go from `working` back to `idle` (status flips before the TUI finishes painting, so still finish with `--wait-stable`). When polling in zsh, do not name the variable `status` — it is readonly there:

```bash
for i in 1 2 3 4 5 6; do
  task_state="$(prowl list --json | jq -r --arg p "$pane" '.data.items[] | select(.pane.id == $p) | .task.status')"
  [ "$task_state" = idle ] && break
  sleep 1
done
prowl read --pane "$pane" --last 200 --wait-stable --json
```

When you need complete output from an agent, prefer writing or redirecting to a file over reading rendered TUI output. Screen capture can be truncated or miss folded content.

For non-interactive agent CLIs, redirect stdout from the shell instead of asking the agent's tool layer to write outside its sandbox:

```bash
prowl send --pane "$pane" \
  'opencode run "Reply exactly: PROWL_OK" > /tmp/prowl-agent-out.txt' \
  --capture --timeout 120 --json
cat /tmp/prowl-agent-out.txt
```

Asking `opencode` or another agent to create `/tmp/...` itself may trigger permission prompts and fail. Shell redirection is usually simpler and more deterministic.

## Targeting Shortcuts

Find by worktree path:

```bash
prowl list --json | jq -r '
  .data.items[]
  | select(.worktree.path | rtrimstr("/") | endswith("/Prowl"))
  | .pane.id
'
```

Find focused pane, usually to exclude it:

```bash
prowl list --json | jq -r '.data.items[] | select(.pane.focused == true) | .pane.id'
```

Human scan:

```bash
prowl list --no-color
```

`-t/--target` can auto-resolve pane UUID, tab UUID, or worktree id/name/path, but explicit `--pane <uuid>` is safer for automation.

## Argument Rules

`send` and `key` positional arguments are count-sensitive:

| command | 0 args | 1 arg | 2 args |
|---|---|---|---|
| `send` | text from stdin | text to focused pane | `<target> <text>` |
| `key` | error | token to focused pane | `<target> <token>` |

Avoid positional targeting in automation. The focused pane changes after `open` and `focus`.

Important combinations:

- `send --capture` waits for completion and sends a trailing Enter. It cannot combine with `--no-wait` or `--no-enter`.
- `send --no-enter` only pre-fills text. Use `key enter` to submit later.
- `key --repeat <1-100>` repeats a token, for example `prowl key --pane "$pane" down --repeat 10`.
- Do not mix stdin input with a positional text argument.

## Quoting

Use outer single quotes when variables should expand in the target pane:

```bash
prowl send --pane "$pane" 'printf "PWD:%s\n" "$PWD"' --capture --timeout 30 --json
```

Avoid outer double quotes around payloads containing `$PWD`, `$VAR`, backticks, or command substitutions unless local expansion is intended.

## Pitfalls

- Never target by tab title alone; use `pane.id` plus path/cwd.
- Never omit `--pane` for `send`, `key`, `read`, or `focus` in automation.
- `open /path` is a project/path navigation command. It may refocus an existing pane and is not a deterministic create command.
- Use `tab create` when automation needs a fresh shell, and capture the returned `pane.id` before sending input.
- Focused pane is not stable; `open` and `focus` change it.
- `read --wait-stable` sees rendered screen only. It cannot recover content folded by a TUI.
- `read` returning fewer lines than `--last` requested is normally `truncated: false` — the pane simply has less history and you already have it all, so do not retry for more. `truncated: true` flags a possibly-incomplete result (the full scrollback could not be read).
- `send --capture` captures a screen diff; multiline input may include command echo.
- `prowl list --json | jq ...` snippets should pass shell values with `--arg`.
- In zsh, do not name variables `status`; it is readonly.
- Parser errors are not JSON even if `--json` is present, because parsing happens before command execution.
- `cmd-w` can close a temporary tab, but double-check the pane first.

## Error Handling

In `--json` mode, command-level failures look like:

```json
{ "ok": false, "error": { "code": "INVALID_ARGUMENT", "message": "..." } }
```

Common codes and recovery:

- `APP_NOT_RUNNING`: Prowl is not reachable. Ask before restarting the app.
- `TARGET_NOT_FOUND` / `TARGET_NOT_UNIQUE`: run `prowl list --json` again and choose an explicit pane UUID.
- `EMPTY_INPUT`: `send` got neither argv text nor stdin.
- `NO_ACTIVE_PANE`: no pane resolved for positional (focused-pane) targeting; pass an explicit `--pane`.
- `INVALID_ARGUMENT`: illegal flag or flag combination, such as `--capture --no-wait`.
- `UNSUPPORTED_KEY` / `INVALID_REPEAT`: check `prowl key --help`.
- `CAPTURE_UNSUPPORTED`: `--capture` needs shell integration (OSC 133) on the target pane. Drop `--capture` and `read --wait-stable` instead, or redirect the command's output to a file (see "Reading Agent Output").
- `WAIT_TIMEOUT`: command did not finish in time; retry with `--no-wait`, or raise `--timeout`.
- `PATH_NOT_FOUND` / `PATH_NOT_DIRECTORY` / `PATH_NOT_ALLOWED`: fix the path passed to `open`.

Always check the exit code before piping output into `jq`; parser-level errors print plaintext usage to stderr.

## Command Set

Current commands: `list`, `read`, `send`, `key`, `focus`, `tab create`, `tab close`, `pane close`, and `open` (default). There is no CLI `quit`; close temporary tabs or panes with explicit `tab close` / `pane close` targets.
