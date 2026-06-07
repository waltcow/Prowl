# Agent Detection

> How Prowl knows there's an agent in a pane and whether it's Working, Blocked,
> Idle, or Done — and which agents it recognizes.

**Keywords:** agent detection, claude, codex, gemini, cursor, working, blocked, idle, done, status, process probe, screen heuristics, indicator, spinner

**Related:** [active-agents](active-agents.md) · [notifications](notifications.md) · [terminal](terminal.md)

## What it is

Prowl continuously inspects each terminal pane to decide whether a coding agent is
running and what state it's in. That signal drives the
[Active Agents panel](active-agents.md), the per-tab activity indicator,
[Canvas](canvas.md) cards lighting up, and [notifications](notifications.md).

## Agents it recognizes

Claude (Claude Code), Codex, Gemini, Cursor, Cline, OpenCode, GitHub Copilot,
Kimi, Droid, Amp, and Pi. Detection covers common wrappers (node, python, bun,
bash, etc.) so agents launched indirectly are still found.

## How detection works (two stages)

1. **Process probe.** Prowl reads the pane's foreground process group and matches
   process names / argv against known agent executables, scoring argv[0] highest,
   then process name, then command-line tokens.
2. **Screen heuristics.** It scans the last ~24 non-blank lines of the pane for
   agent-specific UI cues — e.g. "Esc to interrupt" (working), confirmation/
   permission prompts (blocked), idle prompts. Each agent has its own patterns
   (including spinner glyphs: braille frames, symbol cycles, Cursor's hexagons,
   Kimi's moon phases, etc.).

To avoid flicker, detection **stabilizes**: it tolerates several consecutive
misses before declaring an agent gone, and Claude specifically gets a short
(~1.2s) hold so brief pauses between thinking and output don't drop it out of
"working".

## The state machine

**Raw states:** `working`, `blocked`, `idle`, `unknown`.

**Display states** (what you see):

| Display | Derived from | Meaning |
|---------|--------------|---------|
| **Working** | raw `working` | actively processing |
| **Blocked** | raw `blocked` | waiting for the user (a prompt) |
| **Done** | raw `idle` + **unseen** | just finished; you haven't looked yet |
| **Idle** | raw `idle` + **seen** | nothing running |

A **Done** pane becomes **Idle** the moment you focus it.

## How often it runs

- ~**300 ms** when an agent is present or you're typing (active).
- ~**2 s** when idle.

The heavier process probe is throttled (cached ≈ 0.75 s per process group unless
something changes) so many panes don't add up to high CPU. Status indicators redraw on a
coarse tick rather than every frame for the same reason.

## The indicator

In tabs and the Active Agents panel, a **Working** agent shows an animated spinner
(the per-agent style detected on screen); **Blocked** is a distinct
attention color; **Idle/Done** are static. The "working" animation style is also
configurable in spirit — Prowl uses a bagua/trigram-style spinner in the agents
list.

## Settings

Agent detection is on by default. Related toggles live in the Active Agents and
Notifications settings (e.g. `autoShowActiveAgentsPanel`,
`showActiveAgentTabTitles`).

## Gotchas for agents

- Detection is **heuristic and best-effort**. A short-lived command between polls
  can be missed; an unusual prompt might read as the wrong state.
- **"Blocked"** is the one that means *a human is needed* — it's typically a
  permission/confirmation prompt the agent is waiting on.
- For deterministic automation, don't rely on the visual status; use
  [`prowl list`](cli.md) (`task.status`) and confirm a screen is finished with
  `prowl read --wait-stable` — `task.status` can flip to idle before a TUI has
  painted its last frame.
