# Diff View

> A dedicated window showing what changed in a worktree vs HEAD — review an
> agent's work before you commit.

**Keywords:** diff, diff view, changes, review, working tree, HEAD, split, unified, line changes, ⌘⇧Y, show diff

**Related:** [repositories-and-worktrees](repositories-and-worktrees.md) · [github-pull-requests](github-pull-requests.md) · [command-palette](command-palette.md)

## What it is

The default Diff window shows all changes in the selected worktree's working
directory compared against **HEAD** — exactly what an agent has modified. It's a
fast way to review before committing or merging.

**Open:** click a worktree's diff badge, press `⌘⇧Y` (`show_diff`), or use
Command Palette → "Show Diff".

By default Prowl opens its built-in YiTong-based diff window. In Settings →
General → Diff Tool, you can choose an external tool instead:

- **Built-in** — opens Prowl's diff window. The window is a persistent singleton
  (remembers size/position) and auto-refreshes when it regains focus. `⌘W`
  closes it.
- **Hunk** — opens a new Prowl terminal tab and runs `hunk diff` in the worktree.
- **FileMerge** — creates HEAD/worktree snapshot folders and runs `opendiff`.
- **Kaleidoscope** — creates HEAD/worktree snapshot folders and runs
  `ksdiff --diff`.
- **Custom Command** — creates HEAD/worktree snapshot folders and runs your
  command in the worktree directory. Supported placeholders:
  `{leftPath}`, `{rightPath}`, `{worktreePath}`, `{repoPath}`, and `{branch}`.

Tools that are not installed on the Mac are shown disabled in the Diff Tool menu.

## What the built-in window shows

- A **file list** sidebar of changed files, each with a colored status badge:
  - **M** Modified (orange) · **A** Added/untracked (green) · **D** Deleted (red) ·
    **R** Renamed / **C** Copied (blue) · **?** Unknown (grey).
- The selected file's diff, comparing the **HEAD** version (`git show HEAD:path`)
  against the **on-disk** version.
- Both tracked changes and **untracked new files** are included.

## Modes & interactions

- **Split** (side-by-side, default) or **Unified** view — toggle via the toolbar
  picker.
- Click a file in the list to view its diff.
- Auto-refresh on focus keeps it current as the agent keeps working.

## Line-change badges elsewhere

Repositories can show **line-change badges** (additions/deletions) on worktree
rows, controlled per repo by `observeLineDiffsAutomatically` (on by default).
Disable it for very large repos if it's expensive.

## Availability

Diff is a **git-only** feature — it's unavailable for plain (non-git) folders.

## Gotchas for agents

- The diff is **working-tree vs HEAD**, not vs the base branch — it reflects
  uncommitted changes in that worktree.
- External GUI tools receive snapshot folders so untracked files are included
  without changing the git index.
- The Hunk integration runs in a terminal tab because Hunk is terminal-native.
- For changes already in a pull request (vs the base branch, with CI), see
  [github-pull-requests](github-pull-requests.md).
