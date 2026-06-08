# GitHub / Pull Request Integration

> See a worktree's PR status and CI, and act on it — merge, mark-ready, re-run
> failed jobs, copy failure logs — without leaving Prowl.

**Keywords:** github, pull request, PR, CI, checks, merge, mark ready, re-run, failing jobs, code host, gh cli

**Related:** [command-palette](command-palette.md) · [repositories-and-worktrees](repositories-and-worktrees.md) · [diff-view](diff-view.md) · [settings](settings.md)

## What it is

For git repositories hosted on GitHub, Prowl fetches the pull request associated
with a worktree's branch and exposes its status and actions. It works through the
**`gh` CLI**, so it uses your existing `gh auth` — Prowl never handles tokens
itself.

## What it shows

- PR number, title, state (open/closed/merged), draft status.
- Additions/deletions, author, base/head branches.
- Review decision (approved / changes requested / pending).
- **CI status:** a rollup of all checks (success / failure / in-progress /
  expected / skipped) with failing/success counts and per-check detail URLs.
- **Merge readiness:** Prowl evaluates blockers in order — merge conflicts,
  changes requested, failed checks, other non-mergeable states.
- **Merge queue:** for repos that use GitHub merge queues, an open PR waiting in
  the queue shows a brown **Queued** state in the sidebar and badges, and the PR
  checks popover adds an "In merge queue" row with its position and estimated
  time remaining.

PR status can surface as a badge on the worktree and as a summary in the command
palette.

## Actions (via Command Palette, when a PR exists)

Open the [Command Palette](command-palette.md) (`⌘P`) on a worktree that has a PR:

- **Open Pull Request on GitHub** — open it in the browser. (`⌘⌃G` "Open on Code
  Host" also opens the PR/repo page.)
- **Mark PR Ready for Review** — convert a draft to ready (only when it's a draft).
- **Copy failing job URL** — copy the first failing check's URL.
- **Copy CI Failure Logs** — extract and copy the failed run's logs (great to hand
  back to an agent to fix).
- **Re-run Failed Jobs** — re-trigger the latest failed workflow.
- **Open Failing Check Details** — open a failing check in the browser.
- **Merge PR** — merge when mergeable (not draft, checks pass, no conflicts, no
  changes requested). Merge strategy comes from `pullRequestMergeStrategy`
  (global) or the per-repo override (`merge` / `squash` / `rebase`).
- **Close PR** — close an open PR.

## Requirements & settings

- The **`gh` CLI** must be installed and authenticated (`gh auth login`).
- `githubIntegrationEnabled` (global) gates all GitHub features.
- Per repo: `fetchPullRequestState` (auto-fetch PR state; on by default — turn off
  for big/expensive repos), `pullRequestMergeStrategy` override.
- Settings → **GitHub** tab holds the integration options.

## Gotchas for agents

- No `gh` / not authenticated → no PR features. If a human expects PR actions and
  they're missing, check `gh auth status`.
- PR actions appear in the palette **only when the selected worktree's branch has a
  PR**. No PR → no actions.
- "Copy CI Failure Logs" is the high-value loop for agents: copy logs → feed to the
  agent → it fixes → "Re-run Failed Jobs".
