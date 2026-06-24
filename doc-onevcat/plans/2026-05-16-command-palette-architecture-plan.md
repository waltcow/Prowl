# Command Palette Architecture Refactor

## Context

The command palette (`supacode/Features/CommandPalette/`) ships ~24 commands today. We want to bring it to **60–80 commands** by surfacing view toggles (Canvas/Shelf/Sidebar/Active Agents), navigation actions (next/prev worktree, worktree history), terminal/tab/pane operations, and find-in-terminal — actions currently reachable only via hotkeys or menu items.

Before adding commands, the existing architecture has three issues that would compound at scale:

1. **Confusing visibility model.** Two booleans (`isGlobal`, `isRootAction`) collapse into a single bit of meaningful state. `isGlobal` is named as if it controls "appears in search", but every command participates in search regardless. `isRootAction` is a pure negative override — its only effect is to *hide* items from the empty-query suggestion list. The 8 app-level commands set both flags to `true`, so they never appear when the palette opens; opening Cmd+P shows a blank list in normal use.
2. **No keyword aliases.** The fuzzy scorer only matches `title` and `subtitle`. `Toggle Sidebar` cannot be found by typing `sb`. At 60+ commands users will rely heavily on short queries — keyword support is load-bearing for discoverability.
3. **High cost-per-command.** Adding one command requires changes in `CommandPaletteItem.Kind`, the builder in `CommandPaletteFeature.commandPaletteItems`, the delegate routing in `AppFeature`, and icon/badge rules in the overlay view. There's no factory to compress repetitive registration (e.g., commands that simply forward to an `AppShortcut`).

This plan refactors the foundations first (PR1–PR3), then batches the actual command additions (PR4+).

---

## Design Overview

### New `CommandPaletteItem` shape

```swift
struct CommandPaletteItem: Identifiable, Equatable {
  let id: String
  let title: String
  let subtitle: String?
  let kind: Kind
  let priorityTier: Int
  let category: Category          // NEW: required, drives section grouping
  let keywords: [String]          // NEW: aliases that participate in fuzzy match
  let defaultSuggestion: Bool     // NEW: replaces isGlobal + isRootAction
}

enum Category: String, CaseIterable {
  case view          // Toggle Sidebar / Canvas / Shelf / Active Agents / Diff
  case navigation    // Next/Prev worktree / tab / pane / shelf book / history
  case worktree      // New / Refresh / Archive / Remove / Run / Stop / Open
  case pullRequest   // Open / Merge / Close / Ready / CI actions
  case terminal      // Font size / Find / Ghostty-bridged commands
  case app           // Settings / Check Updates / Open Repository / Install CLI
  #if DEBUG
  case debug
  #endif
}
```

### Why a single `defaultSuggestion` bit (not three-state)

A three-state enum (`alwaysSuggest / onSearch / contextual`) overlaps with what the builder already does. The current builder is context-aware — it only constructs PR commands when an open PR exists; it only adds the worktree icon-change command when a worktree is selected; it filters out unwanted Ghostty actions. **Contextuality lives in command construction**, not in the visibility flag.

That means `defaultSuggestion: Bool` is sufficient and uniform: an item is suggested when (a) it was constructed (the builder decided the context is right) **and** (b) the static `defaultSuggestion` flag is true. PR commands appear in Suggested when a PR exists because the builder constructs them then, not because of any PR-specific filter in the suggestion logic.

This satisfies the constraint *"don't special-case PR commands"* — the suggestion view is one filter + one sort.

### Empty-query rendering (post-PR2)

```
┌──────────────────────────────────────────┐
│  [search box]                            │
├──────────────────────────────────────────┤
│  Recent                                  │
│    • Toggle Canvas              ⌘⌥↩     │
│    • New Worktree               ⌘N      │
│  Suggested                               │
│    • Toggle Sidebar             ⌘⌃S     │
│    • Check for Updates          ⌘⇧U     │
│    • Open Settings              ⌘,      │
│    • …                                   │
└──────────────────────────────────────────┘
```

- **Cap at 8 rows total** (5 Recent + 3 Suggested, dynamic fill).
- **Recent** = items with non-zero recency score, ordered by score desc.
- **Suggested** = remaining items with `defaultSuggestion == true`, ordered by `priorityTier` then declaration order, dedup'd against Recent.
- **Section headers only render on empty query.** When the user types, the scorer takes over: flat, fuzzy-ranked, no headers.

### Keyword scoring

`doScoreFuzzy` will score `title` and each entry in `keywords` independently and take the max. The matched label positions returned for highlighting always come from the `title` scoring run, even when a keyword scored higher — so the UI never paints highlights at indexes that don't exist in the visible string. Keywords are short labels (1–3 words), 0–5 per command, and not displayed.

### Factory for `AppShortcut`-backed commands

```swift
extension CommandPaletteItem {
  static func appShortcut(
    id: String,
    title: String,
    category: Category,
    keywords: [String] = [],
    defaultSuggestion: Bool = true,
    priorityTier: Int = defaultPriorityTier,
    kind: Kind
  ) -> CommandPaletteItem { ... }
}
```

Most batch additions in PR4+ collapse to single-line calls like:

```swift
.appShortcut(
  id: "view.toggle-sidebar",
  title: "Toggle Sidebar",
  category: .view,
  keywords: ["sb", "hide", "left panel"],
  kind: .toggleSidebar
)
```

---

## PR1 — Model Refactor (no behavior change)

**Goal:** swap the two-flag model for `category` + `keywords` + `defaultSuggestion` without changing what the user sees. This PR is pure refactor; any UI/UX change goes to PR2.

### Scope

1. **Add `Category` enum** in `CommandPaletteItem.swift`. Six base cases plus `#if DEBUG case debug`.
2. **Modify `CommandPaletteItem`**:
   - Add `category: Category` (required init param)
   - Add `keywords: [String]` (default `[]`)
   - Add `defaultSuggestion: Bool` (required init param)
   - Delete `isGlobal: Bool` computed property
   - Delete `isRootAction: Bool` computed property
3. **Update `commandPaletteItems` builder** (`CommandPaletteFeature.swift:168-266`) to pass `category` and `defaultSuggestion` for each construction site. Mapping table below — **`defaultSuggestion` must equal `current isGlobal && !isRootAction`** so empty-query behavior is byte-identical.
4. **Update `filterItems`** (line 159–163): replace `items.filter(\.isGlobal).filter { !$0.isRootAction }` with `items.filter(\.defaultSuggestion)`.
5. **Update `ghosttyCommandItems`** helper (line 737–749) to pass `category: .terminal, defaultSuggestion: false`.
6. **Update tests** (`supacodeTests/CommandPaletteFeatureTests.swift`, `AppFeatureCommandPaletteTests.swift`): every `CommandPaletteItem(...)` construction needs the new fields. Existing assertions should still pass — that *is* the verification.

### Command tagging table

| Kind | Category | defaultSuggestion (= current `isGlobal && !isRootAction`) |
|---|---|---|
| `checkForUpdates` | `.app` | false |
| `openSettings` | `.app` | false |
| `openRepository` | `.app` | false |
| `installCLI` | `.app` | false |
| `newWorktree` | `.worktree` | false |
| `refreshWorktrees` | `.worktree` | false |
| `viewArchivedWorktrees` | `.worktree` | false |
| `jumpToLatestUnread` | `.navigation` | false |
| `worktreeSelect` | `.navigation` | false |
| `removeWorktree` | `.worktree` | false |
| `archiveWorktree` | `.worktree` | false |
| `changeFocusedTabIcon` | `.worktree` | false |
| `ghosttyCommand` | `.terminal` | false |
| `openPullRequest` | `.pullRequest` | **true** |
| `openRepositoryOnCodeHost` | `.pullRequest` | false |
| `markPullRequestReady` | `.pullRequest` | **true** |
| `mergePullRequest` | `.pullRequest` | **true** |
| `closePullRequest` | `.pullRequest` | **true** |
| `copyFailingJobURL` | `.pullRequest` | **true** |
| `copyCiFailureLogs` | `.pullRequest` | **true** |
| `rerunFailedJobs` | `.pullRequest` | **true** |
| `openFailingCheckDetails` | `.pullRequest` | **true** |
| `debugTestToast` | `.debug` | **true** |
| `debugSimulateUpdateFound` | `.debug` | **true** |

Result: in normal usage, empty Cmd+P still shows the same things it did before (nothing in the no-PR case; PR commands when a PR is open).

### Verification

- Existing `filterItems` test suite passes unchanged (the public observable behavior is identical).
- Add one new test: `filterItems_emptyQuery_returnsOnlyDefaultSuggestionItems` asserting the post-refactor field reads correctly.
- `make build-app` succeeds.
- `make check` clean (formatting, swiftlint, swift-format).

### Out of scope (deferred to PR2)

- No change to which commands have `defaultSuggestion = true`. The 8 app-level commands stay hidden from empty palette in PR1.
- No keyword data populated yet (`keywords: []` everywhere).
- No section headers in the view.
- No scorer changes.

---

## PR2 — Search & Empty-State UX

**Goal:** make the palette useful on open, and let users search via short aliases.

### Changes

1. **Scorer**: extend `doScoreFuzzy` so each candidate scores against `[title] + keywords`, taking the max. Match highlight positions are always computed against `title`, never keywords.
2. **`filterItems` empty-query path**: replace the simple `defaultSuggestion` filter + sort with a Recent/Suggested split (see Design Overview rendering box). Cap at 8 total.
3. **`CommandPaletteOverlayView`**: add a tiny `Section` wrapper that renders headers — only when the active query is empty. When searching, headers disappear.
4. **Flip `defaultSuggestion` to `true` for the 8 app-level commands.** Add starter keywords:
   - `checkForUpdates` — `["update", "version"]`
   - `openSettings` — `["preferences", "config"]`
   - `openRepository` — `["repo", "add repo"]`
   - `newWorktree` — `["worktree", "branch"]`
   - `refreshWorktrees` — `["reload", "rescan"]`
   - `viewArchivedWorktrees` — `["archive", "history"]`
   - `jumpToLatestUnread` — `["unread", "bell", "notification"]`
   - `installCLI` — `["cli", "command line", "terminal", "prowl"]`

### Verification

- New tests for keyword matching (`Toggle Sidebar` findable via `sb`, etc.).
- New tests for Recent/Suggested split (8-cap, dedup, ordering by recency then priority).
- New tests asserting headers render only when query is empty.
- Manual smoke: open Cmd+P → see populated suggestions; type `sb` → see Toggle Sidebar (note: this command is added in PR4, so PR2's keyword tests use the 8 app-level commands' new keywords).

---

## PR3 — Factories

**Goal:** make PR4+ command additions one-liners. No behavior change.

### Additions

1. **`CommandPaletteItem.appShortcut(id:title:category:keywords:defaultSuggestion:priorityTier:kind:)`** factory — handles the most common case where a command forwards to a hotkey already registered in `AppShortcuts`.
2. **`CommandPaletteItem.ghosttyCommand(_:category:keywords:defaultSuggestion:)`** factory — consumes a `GhosttyCommand` value and returns a tagged item. Replaces `ghosttyCommandItems` inline construction.
3. **`CommandPaletteItem.contextual(id:title:category:kind:)`** factory — for items that are constructed only when context allows (worktree commands, PR commands). `defaultSuggestion` defaults to `false` here.

### Verification

- Refactor existing builders in `commandPaletteItems` to use the new factories. Tests must still pass.
- `make build-app` succeeds.

---

## PR4+ — Batch Command Additions

Each PR adds one category's worth of commands. Suggested order (high → low priority based on user feedback):

### PR4: View toggles + Diff

- Toggle Sidebar (`⌘⌃S`)
- Toggle Active Agents Panel (`⌘⌥P`)
- Toggle Canvas (`⌘⌥↩`)
- Toggle Shelf (`⌘⇧↩`)
- Show Diff (`⌘⇧Y`)

All `category: .view`, `defaultSuggestion: true`.

### PR5: Navigation

- Select Next / Previous Worktree (`⌘⌃↑/↓`)
- Back / Forward Worktree History (`⌘⌥[` / `⌘⌥]`)
- Open Worktree in Finder (`⌘O`)
- Copy Worktree Path (`⌘⇧C`)
- Reveal in Sidebar (`⌘⇧L`)

All `category: .navigation`. Suggested = high-traffic only (Next/Prev Worktree, Jump to Unread already exists).

### PR6: Worktree actions

- Run Script (`⌘R`)
- Stop Script (`⌘.`)
- Pin / Unpin Worktree
- Delete Worktree
- Rename Branch (`⌘⇧M`)

### PR7: Terminal / Tab / Pane

Most pipe through Ghostty's existing actions — confirm each action key is exposed via `GhosttyCommand`. If exposed, register via the existing `.ghosttyCommand` factory; otherwise we may need a Ghostty-side patch (defer that conversation).

- Select Tab 1-9, Prev/Next Tab, Prev/Next Pane, Pane Up/Down/Left/Right
- Font size: increase / decrease / reset
- Find / Find Next / Find Previous / Hide Find
- New / Close Terminal / Close Tab

### PR8: Shelf navigation

- Select Next / Previous Shelf Book
- Select Shelf Book 1-9

### Stretch (no PR yet)

- Repository context menu actions (Settings, Remove)
- Bulk selection actions (Archive Selected, Delete Selected)
- Confirm Worktree Action (`⌘↩`)

---

## Non-goals

- **No registry pattern.** The centralized builder stays — moving to per-feature command contribution is a larger architectural shift that doesn't justify itself at this scale.
- **No frequency tracking on top of recency.** The current exponential-decay recency model is good enough; adding a frequency counter is a measurable-impact-later question.
- **No declarative "availability" framework.** Context conditions stay as `if` branches in the builder. Pulling them out would force every command kind to define an availability predicate, which is heavy for the current ~24 → ~80 jump.
- **No virtualization.** SwiftUI `ForEach` in a `ScrollView` will handle 80 rows fine on macOS 26+.

## Open questions (defer to PR2 design review)

- Should `Recent` show a relative timestamp ("2m ago")? Probably not — adds visual noise for marginal value.
- When a command becomes contextually applicable mid-session (e.g., a PR opens), should its priority in Suggested temporarily boost? Current plan: no — it just shows up because the builder includes it.
- Should keywords be localized? Today the app is English-only; defer until we add localization.
