# Adaptive Line-Diff Strategy & Untracked File Badge

Ref: [#488](https://github.com/onevcat/Prowl/issues/488)

## Background

PR #365 (2026-05-28) replaced fixed-cadence line-diff polling with an
event-driven model. The design was motivated by a user report (#364) of high CPU
usage in a very large repository — `git diff HEAD --shortstat` was running on all
worktrees at a fixed cadence regardless of whether anything had changed.

The solution introduced:

| Parameter | Value | Purpose |
|---|---|---|
| `filesChangedDebounceInterval` | 5 s | Debounce after HEAD watcher fires (branch switch / commit) |
| `lineChangesEventDebounceInterval` | 30 s | Debounce after FSEvents fires (file edits in active worktrees) |
| `lineChangesSafetyRefreshInterval` | 300 s | Fallback for missed FSEvents / sleep-wake |
| `isLineChangesActive` gate | selected ∪ opened | Only active worktrees start FSEvents + safety refresh |
| `observeLineDiffsAutomatically` | per-repo toggle | Escape hatch to disable line-diff entirely |

These values were chosen conservatively for worst-case large repos.

## Problem

For normal-sized repos the 30 s FSEvents debounce makes the sidebar badge feel
"stuck". Users edit a file and the badge takes 30+ seconds to update (if they
keep editing, the timer keeps resetting).

Issue #488 correctly identifies this lag but overstates how cheap
`git diff HEAD --shortstat` is. Our benchmarks on this machine:

| Repo size | Dirty files | Wall time |
|---|---|---|
| 5 000 tracked files | clean | ~14 ms |
| 5 000 tracked files | 5 000 dirty | ~550 ms |
| 20 000 tracked files | clean | ~31 ms |
| 20 000 tracked files | 5 000 dirty | ~484 ms |
| 20 000 tracked files | 20 000 dirty | ~2.0 s |
| 50 000 tracked files | clean | ~67 ms |
| 50 000 tracked files | 10 000 dirty | ~1.1 s |

`--shortstat` still computes line-level diffs (not just metadata) because it
reports `+N/-M` line counts. Cost scales with the number of dirty files, not
repo size alone. For large repos with agents modifying many files concurrently,
sub-second git processes at aggressive intervals compound into sustained CPU
load.

A one-size-fits-all debounce interval cannot serve both audiences.

### Additional finding: untracked files ignored by badge

`GitClient.lineChanges()` runs `git diff HEAD --shortstat`, which only reports
tracked file changes. Newly created (untracked) files are invisible to the badge
while the Diff window (`⌘⇧Y`) includes them via `git ls-files --others
--exclude-standard`. This creates a user-visible inconsistency: the badge shows
+0/-0 but the Diff window lists new files.

## Plan

### Part 1: Adaptive debounce based on repo size

**Core idea**: read the repository's tracked file count once (cheap), classify
the repo into a size tier, and use that tier to select debounce intervals.

#### Reading the file count

The git index binary format stores the entry count as a big-endian `UInt32` at
byte offset 8. Reading 12 bytes from the index file gives an exact count with
zero subprocess overhead.

```
bytes 0–3:  signature ("DIRC")
bytes 4–7:  version (2/3/4)
bytes 8–11: entry count (big-endian UInt32)
```

For worktrees the index lives at the worktree's own git directory (resolved via
the `.git` file → `gitdir:` pointer). Since all worktrees of the same repository
track roughly the same set of files, the count can be cached per
**repository root** and refreshed lazily (e.g. on `setWorktrees` or once per
app-foreground cycle).

Implementation: add a method on `GitClient`:

```swift
nonisolated func indexEntryCount(at gitDir: URL) -> Int? {
  let indexURL = gitDir.appending(path: "index")
  guard let handle = try? FileHandle(forReadingFrom: indexURL) else { return nil }
  defer { try? handle.close() }
  guard let header = try? handle.read(upToCount: 12), header.count == 12 else { return nil }
  return Int(
    header[8...11].withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
  )
}
```

#### Size tiers and intervals

| Tier | Tracked files | FSEvents debounce | HEAD debounce | Safety refresh |
|---|---|---|---|---|
| Small | < 5 000 | 2 s | 1 s | 300 s |
| Medium | 5 000 – 20 000 | 5 s | 2 s | 300 s |
| Large | > 20 000 | 15 s | 5 s | 300 s |

The existing `observeLineDiffsAutomatically = false` toggle remains the hard
opt-out for truly massive repos where even 15 s is too aggressive.

Thresholds are tentative — we can tune after real-world feedback.

#### Where to apply

`WorktreeInfoWatcherManager` currently takes `filesChangedDebounceInterval` and
`lineChangesEventDebounceInterval` as constructor parameters (single values for
all worktrees). Change these to be resolved **per worktree** by looking up the
cached repo file count and mapping to a tier.

Specifically:
- `scheduleFilesChanged(worktreeID:)` — use the per-repo HEAD debounce.
- `scheduleLineChangesDebouncedRefresh(worktreeID:)` — use the per-repo FSEvents
  debounce.

The file count cache lives on `WorktreeInfoWatcherManager` as a
`[URL: Int]` dictionary keyed by repository root URL. It is populated when
worktrees are set / updated, and refreshed on app-foreground. No async work
needed — the index read is synchronous and takes <1 ms.

#### Tier resolution

Add a helper that maps a file count to debounce intervals:

```swift
struct LineChangesTimingTier {
  let filesChangedDebounce: Duration
  let eventDebounce: Duration
}

func lineChangesTimingTier(forFileCount count: Int) -> LineChangesTimingTier {
  switch count {
  case ..<5_000:
    return LineChangesTimingTier(filesChangedDebounce: .seconds(1), eventDebounce: .seconds(2))
  case ..<20_000:
    return LineChangesTimingTier(filesChangedDebounce: .seconds(2), eventDebounce: .seconds(5))
  default:
    return LineChangesTimingTier(filesChangedDebounce: .seconds(5), eventDebounce: .seconds(15))
  }
}
```

### Part 2: Include untracked file lines in the badge

#### Approach

Count the **lines** in untracked files and fold them into the existing `+N`
number. No layout change to the badge — untracked lines are conceptually
"added lines" (they would show as `+` in a full diff).

#### GitClient change

`lineChanges(at:)` currently returns `(added: Int, removed: Int)?`. Keep the
same return type — the `added` count now includes untracked line counts.

Inside `lineChanges(at:)`, run the existing `git diff HEAD --shortstat` and
`git ls-files --others --exclude-standard` concurrently via `async let`:

```swift
async let diffOutput = runGit(operation: .lineChanges, arguments: [..., "diff", "HEAD", "--shortstat"])
async let untrackedOutput = runGit(operation: .untrackedFilePaths, arguments: [..., "ls-files", "--others", "--exclude-standard"])

let tracked = parseShortstat(await diffOutput)
let untrackedPaths = parseUntrackedPaths(await untrackedOutput)
let untrackedLines = countLinesInFiles(untrackedPaths, relativeTo: worktreeURL)

return (added: tracked.added + untrackedLines, removed: tracked.removed)
```

`countLinesInFiles` reads each file's `Data` and counts `0x0A` bytes. If a NUL
byte (`0x00`) appears in the first 8 KB, the file is treated as binary and
skipped (matches git's heuristic). This is pure in-process I/O with no
subprocess overhead.

Performance: 1 000 untracked files × 100 lines = ~43 ms total (including the
`git ls-files` subprocess). The `async let` parallelism means it overlaps with
`git diff HEAD --shortstat` and adds minimal wall-clock time.

#### Badge display

No change to layout. The `+N` number now reflects tracked additions +
untracked file lines combined.

Before: `+120 -45` (tracked only; creating a new 30-line file shows nothing)
After:  `+150 -45` (30-line new file adds to the count)

## Scope and non-goals

- **Not changing `isLineChangesActive` gating**: inactive worktrees still don't
  run FSEvents monitors. This is correct — a worktree you haven't opened doesn't
  need sub-second freshness. The existing deferred refresh on open/select is
  sufficient.
- **Not changing PR polling**: already batched via `PullRequestRefreshCoordinator`
  into a single GraphQL call per host. Not a scaling concern.
- **Not exposing debounce intervals to users**: the adaptive tier handles it
  automatically. `observeLineDiffsAutomatically = false` remains the manual
  escape hatch.
- **Not replacing `git diff HEAD --shortstat`** with `git status --porcelain` or
  similar. The current command gives exact line counts which the badge needs;
  `--porcelain` would give file counts only.

## Affected files

| File | Change |
|---|---|
| `GitClient.swift` | Add `indexEntryCount(at:)`; add `countLinesInFiles` helper; extend `lineChanges()` to include untracked lines in `added` |
| `WorktreeInfoWatcherManager.swift` | Per-repo file count cache; per-worktree tier resolution for debounce intervals |
| `RepositoriesFeature+CoreReducer.swift` | No change needed — `added` already flows through |
| `WorktreeInfoWatcherManagerTests.swift` | Test tier selection; test debounce varies by repo size |

## Testing

- Unit test `indexEntryCount` with a hand-crafted 12-byte header.
- Unit test `lineChangesTimingTier` for boundary values.
- Unit test `countLinesInFiles`: text files counted, binary files (NUL in first
  8 KB) skipped, missing files skipped.
- Watcher manager tests: verify that worktrees in repos of different sizes get
  different debounce intervals.
- Manual: open a small repo, edit a file, verify badge updates within ~2 s.
  Create a new file, verify its lines appear in the `+N` count.
  Toggle `observeLineDiffsAutomatically = false`, verify badge stops updating.
