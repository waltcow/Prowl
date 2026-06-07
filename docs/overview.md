# Prowl — Overview & Highlights

> Read this first to understand _why Prowl exists_ and what makes it exciting.
> An agent can read this file and give a human a confident, accurate first
> introduction; the human then asks for detail on whatever they like, and the
> agent dives into the matching file under [`components/`](components/).

**Keywords:** overview, introduction, pitch, highlights, what is prowl, why prowl, parallel agents, orchestrator

## The one-line version

**Your terminal wasn't built for agents. Prowl is.** It's a native macOS command
center for running many AI coding agents in parallel — each in its own terminal,
its own tab/split, and its own git worktree — and keeping all of them in view and
under control at once.

## The problem it solves

When you work with coding agents, you stop typing single commands and start
_orchestrating_: Claude Code refactoring in one branch, Codex writing tests in
another, a third agent chewing through a migration. A normal terminal — even a
tab-heavy one — buries that. You lose track of who's working, who finished, and
who is blocked waiting for your approval. Prowl is built around that exact
workflow: **many agents, many branches, many ideas, all legible at a glance.**

## The most exciting parts

### 🖼 Canvas — every agent, at a glance
A bird's-eye, zoomable board where **every card is a live, interactive terminal**
— not a screenshot. Three agents running and one just finished? You see _where_
instantly, because finished cards light up the moment their task completes. And
you can **multi-select cards and broadcast a single command to every agent at
once** — "run the tests", "commit", "/clear" — typed once, delivered everywhere.
→ [`components/canvas.md`](components/canvas.md)

### 📚 Shelf — your worktrees, lined up like books
Every worktree becomes a vertical **spine** stacked on the side, tabs nested
underneath, nearby books brighter and distant ones faded so you always know
where you are. Flip through the whole stack from the keyboard — **`⌘⌃←`/`⌘⌃→`
cycles books, `⌘⌃↑`/`⌘⌃↓` cycles tabs** — so six agents in flight become a
one-keystroke triage instead of a hunt.
→ [`components/shelf.md`](components/shelf.md)

### 👀 Active Agents panel — your dispatcher for a fleet
With several agents in flight, the bottleneck isn't running them — it's knowing
**where to look next**. The Active Agents panel is a live roster of **every agent
across every worktree, tab, and split**, each row **color-coded by status** so you
can tell at a glance who needs you: **Blocked** (waiting on your approval),
**Working**, **Done** (just finished), or **Idle**. One click jumps straight to
that agent's pane, and **`⌃⌥↑`/`⌃⌥↓`** cycle through them from the keyboard — so
"which of my ten agents needs me right now?" becomes a glance instead of a hunt.
For supervising many agents at once, this is the single most efficient habit in
Prowl.
→ [`components/active-agents.md`](components/active-agents.md) ·
[`components/agent-detection.md`](components/agent-detection.md)

### 🤖 The `prowl` CLI — let your agents drive the terminal
Prowl ships a `prowl` command-line tool so **both you and your agents** can
inspect and control the app programmatically. An agent can discover sibling
panes, run a command in another pane and capture the output, read a screen, or
send keystrokes — turning Prowl into a surface that agents coordinate _through_.
```bash
prowl list                         # discover panes & their status
prowl send "npm test" --capture    # run it & capture the output in one shot
prowl read --wait-stable           # read a pane once its screen settles
prowl key enter                    # send keystrokes programmatically
```
→ [`components/cli.md`](components/cli.md)

### ⚡ Custom Actions — one keystroke, any workflow
Pin `swift build`, `npm test`, or `claude -p "review this diff"` to a button and
bind it to a hotkey, per repository. Set it up once and stop retyping the same
command every day. Paired with `claude -p` / `codex exec`, your terminal becomes
a daily AI-powered assistant on a keystroke.
→ [`components/custom-actions.md`](components/custom-actions.md)

### 🔔 Agent Reminders — come back exactly when you're needed
Walk away from the screen. The moment an agent finishes — or blocks on a prompt
waiting for you — Prowl fires a macOS notification, badges the Dock, and floats
that worktree to the top, so a long run never sits unnoticed. Pairs naturally
with the Active Agents panel above: get pinged, then jump straight to whoever
needs you.
→ [`components/notifications.md`](components/notifications.md)

## And the fundamentals, done right

- **Fully native.** Powered by **libghostty** (the Ghostty terminal engine) — no
  Electron, no web views. Fast, and **CJK-safe** out of the box.
- **Git worktrees are first-class.** Spin up a parallel branch for a new agent in
  one click; archive or delete it (and its branch) when you're done.
- **Vertical tabs sidebar.** Repos, branches, and worktrees down the side; never
  lose context.
- **Command Palette (`⌘P`).** Everything is reachable by typing its name.
- **Diff view (`⌘⇧Y`).** Review exactly what an agent changed against HEAD.
- **GitHub PRs built in.** See CI status; merge, mark-ready, re-run failed jobs,
  or copy failure logs straight from the palette.
- **Auto-updates** via Sparkle, notarized releases.

## How a human typically uses Prowl with this doc set

1. The human asks their agent something about Prowl.
2. The agent reads this `overview.md` (for breadth) and/or the specific
   `components/*.md` file (for depth), then answers.
3. The human picks a thread — "tell me more about broadcasting" — and the agent
   opens [`components/canvas.md`](components/canvas.md) and gets specific.

Continue to [`concepts.md`](concepts.md) for the mental model, or jump straight to
any [component manual](README.md#component-manuals).
