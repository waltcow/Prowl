# Shelf View

> Worktrees as vertical "book spines" stacked on the side — flip through your
> whole stack from the keyboard, never losing your place.

**Keywords:** shelf, book, spine, vertical tabs, flip, cycle books, cycle tabs, triage, proximity, stack

**Related:** [view-modes](view-modes.md) · [canvas](canvas.md) · [terminal](terminal.md) · [keyboard-shortcuts](../reference/keyboard-shortcuts.md)

## What it is

Shelf lays your worktrees out as thin vertical **spines** ("books") on the sides,
with the currently open book's terminal filling the center. Each spine shows the
project icon/name (rotated) and a column of its **tabs** as small icon slots.
Books near the open one are brighter; distant ones fade — so you always know where
you are in the stack.

**Toggle Shelf:** `⌘⇧↩` (`toggle_shelf`). Requires at least one open worktree;
otherwise it's a no-op.

## Keyboard navigation (the whole point)

| Action | Key |
|--------|-----|
| Flip to **next book** (worktree) | `⌘⌃→` |
| Flip to **previous book** | `⌘⌃←` |
| Jump to **book 1–9** | `⌥⌃1` … `⌥⌃9` |
| Cycle the open book's **tabs** | `⌘⌃↓` (next) / `⌘⌃↑` (previous) |
| Select the open book's **tab 1–9** | `⌘1` … `⌘9` |

So `⌘⌃←/→` moves **between agents**, and `⌘⌃↑/↓` moves **between that agent's
tabs** — triage six in-flight agents one keystroke at a time.

## Interacting with spines

- **Open a book:** click anywhere on a closed spine (it activates and shows its
  terminal).
- **Select a tab:** click a tab slot on the open book's spine.
- **New tab:** the **+** at the bottom of a spine. On a closed book, **+** opens
  the book and creates the tab.
- **Split:** the open book's spine has **split-vertical** and **split-horizontal**
  buttons (Ghostty `new_split:right` / `new_split:down`).
- **Close a tab:** hover a tab slot → its **×**.
- **Tab context menu:** right-click a tab slot → Rename, Change Icon, Close, Close
  Others, Close to Right, Close All.
- **Spine header context menu:** right-click → **Repo Settings**, **Close
  Worktree/Folder** (closes all its tabs, removing the book).

While holding `⌘`, the open book overlays its tab slots with `1…9` hints for quick
selection.

## Visual cues

- **Open book:** full-strength color. **Neighbors:** ~50%. Farther books fade
  progressively — a proximity ladder that keeps the stack readable.
- **Unread notification:** a tab slot highlights orange; the spine header shows an
  orange dot.
- Spine tint follows the **repository color** when set (toggle
  `shelfSpineTintFollowsRepositoryColor`); otherwise a fallback
  (`shelfSpineTintFallback`: neutral or system tint) is used.
- In Shelf, the toolbar and leading band are tinted with the open book's repo
  color (`windowTintMode`).

## Empty state

If no book is open, the center shows "No worktree selected" with a books icon;
spines stay visible so you can pick one.

## Settings that affect Shelf

- `defaultViewMode` — launch directly into Shelf.
- `shelfSpineTintFollowsRepositoryColor` — color spines by repo color.
- `shelfSpineTintFallback` — `neutral` or `systemTint` when a repo has no color.
- `windowTintMode` / repository colors — chrome tinting.

## When to recommend Shelf vs Canvas

- **Shelf** = linear, keyboard-driven, see-one-at-a-time triage of many
  worktrees. Fastest way to cycle through agents and check each.
- **Canvas** = spatial, all-at-once supervision and broadcast.

See [view-modes](view-modes.md).

## Gotchas for agents

- A "book" is a **worktree**; a tab slot is a **tab** within it.
- Closing the last tab of a book removes the book from the shelf.
- The book-cycling keys (`⌘⌃←/→`) and tab-cycling keys (`⌘⌃↑/↓`) differ only by
  arrow direction — be precise when describing them.
