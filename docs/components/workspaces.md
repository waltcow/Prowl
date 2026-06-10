# Workspaces

**Keywords:** workspace, multi-repo, many repositories, agent cwd, `.prowl/workspace.json`, workspace metadata, `prowl list`

Workspaces let one agent work on a task that spans several repositories. A
workspace is a folder added to Prowl as a runnable project, with metadata at
`.prowl/workspace.json` describing the repositories inside it.

When you open a workspace in Prowl:

- The terminal starts in the workspace root.
- The sidebar/detail view uses the workspace title and repository list from
  `.prowl/workspace.json`.
- The `prowl` CLI reports the runnable target's `worktree.kind` as `workspace`.
- Git worktree, branch, diff, and PR controls remain per-repository features; a
  workspace is intentionally a multi-repo working directory rather than a single
  git repository.

## Folder layout

Use **New Workspace** from the sidebar toolbar, Worktrees menu, or command
palette to create a workspace. Prowl creates the shared folder, materializes the
selected repositories, writes `.prowl/workspace.json`, and opens the workspace
as a runnable folder. A workspace needs at least two repositories.

While a workspace is being created the prompt shows a spinner. **Cancel** stops
the creation and rolls back everything created so far: cloned folders, created
worktrees, and the workspace folder itself when Prowl created it.

```text
my-feature-workspace/
├─ .prowl/
│  └─ workspace.json
├─ app/
├─ api/
└─ shared-package/
```

Repository sources can be mixed in one workspace:

- Already opened repositories can be inserted from the **Add Opened** menu
  (`source_kind: existing_path`).
- Local repository folders are selected from disk
  (`source_kind: local_repository`).
- Remote repositories are added through a URL prompt that loads remote heads
  before inserting the row. They are cloned into the workspace folder with
  `source_kind: remote`. The inserted row defaults to **Use Existing** on the
  detected default remote branch.
- Bare repositories are materialized with `git worktree add` and recorded with
  `source_kind: bare_repository`. If both branch and base ref are supplied,
  Prowl creates the worktree branch from that base ref.

For already opened and local repositories, the branch action decides how the
folder is materialized:

- **Link** (the default) adds a symlink to the repository as it is on disk, so
  the workspace shares the live checkout.
- **Create Branch** runs `git worktree add -b` against the source repository:
  the workspace gets an isolated checkout on a new branch created from the
  selected base ref, without touching the source repository's own checkout. The
  new worktree also appears in the source repository's worktree list.
- **Use Existing** runs `git worktree add` with the selected ref. Git rejects a
  local branch that is already checked out elsewhere.

The creation prompt detects base-ref candidates for already opened, local, and
bare repositories by reading local git refs, preferring the detected default
branch such as `main` or `master`. Refs are grouped as local branches, remote
tracking branches, or fetched remote branches, and the picker supports simple
text search. Remote default-branch pointers are shown explicitly, such as
`origin/HEAD`. Base refs are selected from detected refs so workspace creation
does not try to checkout an arbitrary, nonexistent branch.

Branch behavior is explicit:

- **Create Branch** uses `branch_name` plus the selected base ref to create a
  new branch or worktree branch. A branch name is required in this mode for
  every source kind.
- **Use Existing** uses the selected ref directly. For remote clones, Prowl
  checks out the selected remote branch after clone; Git creates the normal
  local tracking branch for refs such as `origin/feature`. For bare
  repositories, Prowl passes the selected ref to `git worktree add`, so local
  branch refs produce branch worktrees and remote-tracking refs produce detached
  worktrees.

## Metadata

Example `.prowl/workspace.json`:

```json
{
  "title": "Checkout Flow",
  "description": "Update app UI, API contract, and shared package together.",
  "task_links": [
    "https://github.com/onevcat/Prowl/issues/123"
  ],
  "repositories": [
    {
      "name": "App",
      "role": "macOS app",
      "path": "app",
      "source_kind": "local_repository",
      "source_location": "/Users/mikoto/Documents/Repos/github/Prowl",
      "branch_name": "codex/checkout-flow"
    },
    {
      "name": "API",
      "role": "backend",
      "path": "api",
      "source_kind": "remote",
      "source_location": "git@github.com:onevcat/api.git",
      "base_ref": "main"
    },
    {
      "name": "Shared Package",
      "role": "library",
      "path": "shared-package",
      "source_kind": "bare_repository",
      "source_location": "/Users/mikoto/Documents/Repos/bare/shared-package.git",
      "branch_name": "codex/checkout-flow"
    }
  ]
}
```

Top-level fields:

- `id` — optional stable identifier. Defaults to the workspace root path.
- `title` — display title. Defaults to the folder name.
- `description` — optional task summary shown in the detail view.
- `task_links` — optional links or identifiers for the work item.
- `repositories` — repo entries that belong to the workspace.
- `created_at` / `updated_at` — optional ISO-8601 timestamps.

Repository entry fields:

- `id` — optional stable identifier. Defaults to `path`.
- `name` — display name. Defaults to the last path component.
- `role` — optional short role such as `app`, `backend`, or `docs`.
- `path` — relative path under the workspace root, or an absolute path.
- `source_kind` — `existing_path`, `remote`, `local_repository`, or
  `bare_repository`.
- `source_location` — optional remote URL, local repository path, or bare repo
  path.
- `branch_name` — optional branch/worktree name expected for the task.
- `base_ref` — optional base branch or ref.

## Agent usage

Because the terminal cwd is the workspace root, agents can inspect and modify
all listed repositories in one session:

```bash
git -C app status
git -C api status
git -C shared-package status
```

Use the metadata as the contract: it tells the agent which repos are in scope,
where they are on disk, and what role each repo plays in the task.
