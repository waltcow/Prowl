# Foundation Model Auto Branch Name Suggestion

## Context

When creating a new worktree in Prowl, users must manually type a branch name (e.g.,
`feature/my-change`). This is friction-heavy. We want to use Apple's on-device Foundation
Model (macOS 26+ `FoundationModels` framework) to automatically suggest a branch name
based on available context: terminal tab content/titles, existing branch naming conventions,
and repository name.

If Foundation Model is unavailable (older hardware, etc.) or the suggestion fails, fall back
to the existing `WorktreeNameGenerator` (adjective-animal-NNN format, e.g., `bold-cat-042`).

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Timing | Dialog opens immediately, name fills async | Don't block UI; user can start typing |
| Fallback | Random name (adjective-animal-NNN) | Both prompt and non-prompt paths |
| Clipboard | Skip entirely | Avoid macOS paste indicator + privacy concerns |
| LLM layer | Protocol-based abstraction | Foundation Model as default; extensible for future backends |

## Information Sources (by signal priority)

1. **Terminal pane titles** — Set via OSC-2, often contain running commands. Available from
   `bridge.state.title`. Cheap to read.
2. **Terminal active content** — Read via `readActiveContentsForCLI()` (active command area,
   not full scrollback). Cap per worktree at ~300 chars, total ~1000 chars, max 3 worktrees.
3. **Existing branch names** — Already loaded in `baseRefOptions`. Use first 10 for naming
   convention inference.
4. **Repository name** — Already in state.

## Data Sources (by importance)

| Priority | Source | Role in prompt | Notes |
|----------|--------|----------------|-------|
| 1 | Existing branch names (`baseRefOptions`) | Naming convention examples — model must match style | `feature/xxx`, `fix/xxx`, pure kebab, etc. |
| 2 | Same-repo worktree branch names (`Worktree.name`) | Current work context — what user is working on | Sorted by `lastDefocusedAt`, top 3 |
| 3 | Terminal pane titles (OSC-2) | Current work context — running commands/agent names | Grouped with branch names per worktree |
| 4 | Terminal active content | Supplementary context — errors, discussions | Truncated, appended last; noisiest source |
| 5 | Repository name | Background context | One line at prompt start |

## Phase 0: Spike — Validate Foundation Model Capability

Before committing to the full integration, build a standalone Swift command-line tool to
test Foundation Model's ability to generate useful branch names.

**Goal**: Determine if on-device model quality and speed are sufficient. If not, skip AI
integration and only ship the random name feature.

**Spike program** (temporary directory, not kept in repo):
- Simple Swift Package with `FoundationModels` import
- Hardcoded test scenarios simulating real context combinations
- Test cases:
  1. **Convention only** — give 10 branch names → can model infer and match the style?
  2. **Convention + worktree branches + pane titles** — give branch names + "current worktree:
     feature/add-canvas-tile, pane title: claude" → does it produce a sensible related name?
  3. **Convention + terminal active content** — give branch names + truncated terminal output
     (e.g., error messages, `git log` output) → can model extract intent from noisy text?
  4. **Full context** — all sources combined → best quality achievable?
  5. **Speed** — measure response latency per call. Is 3-second timeout realistic?
- Try 2-3 prompt variations per test case (directive style, few-shot examples, etc.)
- Log raw model output + sanitized branch name for each

**Success criteria**:
- Model generates contextually relevant names in ≥ 3/5 test scenarios
- Response latency < 3 seconds on Apple Silicon
- Output is parseable (single line, no extra explanation)

**If spike fails**: Ship only the random name (adjective-animal-NNN) feature, skip LLM layer.

## Architecture

### LLM Service Layer

A lightweight protocol-based abstraction to decouple the LLM backend from business logic.
Foundation Model is the initial and default backend; the design preserves extensibility for
future backends (stronger models, remote LLMs, etc.) without over-engineering.

```
┌─────────────────────────────────────────────────┐
│  BranchNameSuggestionClient (TCA Dependency)    │
│  - gatherContext(...)  → context                │
│  - suggest(context)    → String?                │
└──────────────┬──────────────────────────────────┘
               │ uses
┌──────────────▼──────────────────────────────────┐
│  LLMService (protocol)                          │
│  - func generate(prompt: String) async → String?│
└──────────────┬──────────────────────────────────┘
               │ conforms
┌──────────────▼──────────────────────────────────┐
│  FoundationModelLLMService                      │
│  - Wraps LanguageModelSession (macOS 26+)       │
│  - Checks availability, handles timeout         │
└─────────────────────────────────────────────────┘
```

**`LLMService` protocol** (`supacode/Infrastructure/LLM/LLMService.swift`):
```swift
protocol LLMService: Sendable {
  var isAvailable: Bool { get async }
  func generate(prompt: String) async throws -> String
}
```

**`FoundationModelLLMService`** (`supacode/Infrastructure/LLM/FoundationModelLLMService.swift`):
- Wraps `FoundationModels.LanguageModelSession`
- Checks `SystemLanguageModel.default` availability
- Applies 3-second timeout
- Returns raw text response

**`BranchNameSuggestionClient`** (`supacode/Clients/BranchNameSuggestion/BranchNameSuggestionClient.swift`):
- TCA dependency consuming `LLMService`
- Gathers terminal context on `@MainActor`
- Builds prompt, calls `LLMService.generate`, sanitizes output
- Applies prefix enforcement (detect convention from existing branches, fallback `worktree/`)
- Validates result before returning (see validation rules below)
- Falls back to `nil` on any failure (caller handles random fallback)

### Context Gathering

```swift
struct BranchNameSuggestionContext: Sendable, Equatable {
  let repositoryName: String
  let existingBranchNames: [String]    // first 10, for convention inference
  let terminalContexts: [TerminalHint]

  struct TerminalHint: Sendable, Equatable {
    let worktreeBranch: String         // Worktree.name (= branch name)
    let title: String                  // pane title (OSC-2)
    let activeContent: String?         // truncated active area text
  }
}
```

`gatherContext` is a `@MainActor` closure wired in `supacodeApp.swift`, capturing
`terminalManager`. It:

1. **Filters by same repo** — only includes worktrees where
   `state.repositoryRootURL == targetRepositoryRootURL`
2. **Sorts by last active** — uses `WorktreeTerminalState.lastDefocusedAt` (new field,
   set when worktree loses focus via `setSelectedWorktreeID`). Currently selected worktree
   ranks first, then by `lastDefocusedAt` descending
3. **Takes top 3** — reads tab/pane titles via `makeCLIListSnapshot()` and active content
   via `readActiveContentsForCLI()` for each worktree's focused pane
4. **Includes branch name** — `Worktree.name` per worktree, valuable context for the model
5. **Truncates** — per-pane active content capped at ~300 chars, total budget ~1000 chars

### `lastDefocusedAt` Tracking

Add `var lastDefocusedAt: Date?` to `WorktreeTerminalState`. Set it in
`WorktreeTerminalManager.handleCommand(.setSelectedWorktreeID)` on the **previous** state
(line 169 of `WorktreeTerminalManager.swift`) when focus moves away. Lightweight, in-memory
only, no persistence needed.

### Prompt Design (V3, prefix-enforced)

Spike validated that V3 (explicit prefix enforcement) performs best. The prompt dynamically
detects prefixes from existing branches and instructs the model to use them.

```
Suggest a single git branch name for a new branch in the "{repositoryName}" repository.

Rules:
- Output ONLY the branch name, nothing else
- Maximum 50 characters
- IMPORTANT: Existing branches use prefixes: {detected prefixes}. You MUST use one of these prefixes.
- Do NOT repeat an existing branch name

Existing branches: {first 10 branch names, comma-separated}
{if terminalContexts}
Current work in progress:
- Branch: {branch}, terminal: {paneTitle} | {activeContent truncated}
{/if}
```

When no prefix convention is detected (fresh repo), the prefix instruction is replaced with
"Use a descriptive kebab-case name."

### Branch Name Sanitizer & Validation

**`BranchNameSanitizer`** (`supacode/Domain/BranchNameSanitizer.swift`):

**Sanitization** — convert arbitrary text to a valid git branch name:
- Trim whitespace, lowercase
- Replace spaces/underscores with hyphens
- Strip invalid git-ref characters (`~`, `^`, `:`, `\`, `?`, `*`, `[`, `..`, `@{`)
- Collapse consecutive hyphens, strip leading/trailing hyphens and dots
- Truncate to 50 characters

**Prefix enforcement** — post-sanitization:
- Detect the most common prefix from existing branches (`feature/`, `fix/`, etc.)
- If sanitized name has no `/` prefix, prepend the detected convention prefix
- If no convention exists, prepend `worktree/`

**Validation** — return `nil` (trigger random fallback) if any of these fail:
1. Name duplicates an existing branch (case-insensitive)
2. Name is too short (< 3 characters after sanitization)
3. Name is too long (> 50 characters after sanitization + prefix)
4. Sanitization produced an empty string (garbage input, multi-line output, etc.)

## Integration into Worktree Creation Flow

### Prompt path (dialog shown)

1. User triggers Cmd+N → `createRandomWorktreeInRepository`
2. `.run` effect loads branch refs (existing) + gathers context + calls `suggest` in parallel
3. `promptedWorktreeCreationDataLoaded` → dialog opens with `branchName: ""`,
   `isSuggestingName: true`, `randomPlaceholder` pre-generated as random name
4. AI suggestion arrives → `branchNameSuggestionReceived(name)`
   - Does NOT auto-fill input field — suggestion only shown in dim hint line below
   - Hint line shows "Auto suggestion: {name}" with a "Use" button
   - Hover tooltip explains the suggestion source (on-device AI, context-based)
5. `isSuggestingName = false` → loading indicator disappears, suggestion hint visible
6. User clicks "Create" → uses **effective name**: user input if non-empty, else random
   placeholder. Empty input no longer blocks creation.

### Non-prompt path (auto-create without dialog)

**No change.** When `promptForWorktreeCreation == false`, keep using `nameSource: .random`
directly. This path is designed for instant worktree creation ("don't ask me"); adding AI
latency would violate that intent. AI naming only applies to the dialog path.

### State Changes in `WorktreeCreationPromptFeature`

Add to `State`:
- `var isSuggestingName: Bool = false`
- `var suggestedBranchName: String?` — stores the AI suggestion for display
- `let randomPlaceholder: String` — pre-generated random name, shown as placeholder
- Computed `effectiveBranchName: String` — returns `branchName` if non-empty, else
  `randomPlaceholder`. Used by submit and path preview.

Add to `Action`:
- `case branchNameSuggestionReceived(String?)` — AI result arrived
- `case useSuggestedBranchName` — user tapped "Use" button on the hint

Reducer logic:
- `branchNameSuggestionReceived(name)`: set `isSuggestingName = false`,
  store `suggestedBranchName = name`. Does NOT auto-fill `branchName`.
- `useSuggestedBranchName`: copy `suggestedBranchName` into `branchName`.
- `createButtonTapped`: use `effectiveBranchName` instead of `branchName` for validation
  and submit. Empty input is no longer an error (falls through to random placeholder).

### UI Changes in `WorktreeCreationPromptView`

**Branch name field**:
- Placeholder shows the pre-generated random name (e.g., `bold-cat-042`)
- Empty input is allowed — placeholder name will be used on submit
- Text field remains editable at all times

**Loading state** (`isSuggestingName == true`):
- Show a subtle `ProgressView` near the text field (trailing overlay)

**Suggestion hint** (`suggestedBranchName != nil`):
- Below the input field: "Auto suggestion: {name}" in dim/tertiary style
- "Use" button alongside (clicking copies suggestion into input field)
- Hover tooltip: explains this is an on-device AI suggestion based on repo context
- Visible regardless of whether the user has typed anything
- Hidden once user submits (Create) or cancels

## Files to Create

| File | Purpose |
|------|---------|
| `supacode/Infrastructure/LLM/LLMService.swift` | Protocol for LLM backends |
| `supacode/Infrastructure/LLM/FoundationModelLLMService.swift` | Foundation Model backend |
| `supacode/Clients/BranchNameSuggestion/BranchNameSuggestionClient.swift` | TCA dependency |
| `supacode/Domain/BranchNameSanitizer.swift` | Branch name sanitization utility |

## Files to Modify

| File | Change |
|------|--------|
| `WorktreeCreationPromptFeature.swift` | Add `isSuggestingName`, suggestion action |
| `RepositoriesFeature+WorktreeCreation.swift` | Kick off suggestion in parallel, handle non-prompt path |
| `RepositoriesFeature.swift` | Add `CancelID.branchNameSuggestion`, dependency declaration |
| `WorktreeCreationPromptView.swift` | Loading indicator + suggestion hint with "Use" button |
| `supacodeApp.swift` | Wire `BranchNameSuggestionClient` dependency |
| `WorktreeTerminalState.swift` | Add `lastDefocusedAt: Date?` property |
| `WorktreeTerminalManager.swift` | Set `lastDefocusedAt` on focus-away in `setSelectedWorktreeID` |

## Verification

1. `make build-app` — ensure it compiles
2. Run app on macOS 26 with Apple Silicon → Cmd+N → verify AI-suggested name appears
3. Test with other terminal tabs open containing agent sessions → expect contextual name
4. Test with Foundation Model unavailable → expect random adjective-animal-NNN fallback
5. Test typing before suggestion arrives → verify suggestion doesn't overwrite user input
6. Test non-prompt path (setting off) → verify AI name is used instead of random
