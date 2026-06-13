# Prowl CLI Agents Command Plan

## Context

Issue: <https://github.com/onevcat/Prowl/issues/330>

The request is to expose the same Active Agents roster that Prowl already shows
in the sidebar through the `prowl` CLI. The CLI should be read-only for this
feature: switching/focusing is already covered by existing commands such as
`prowl focus --pane <id>`, `prowl read --pane <id>`, and `prowl send --pane <id>`.

Before implementing the command, agent detection scheduling should be made
reliable and efficient independently of the Active Agents panel visibility. The
CLI command should not depend on whether the panel is expanded, whether Shelf
status markers are visible, or any other UI-only preference.

## Proposed Command

Add:

```bash
prowl agents
prowl agents --json
```

Do not add a first-class "switch agent" subcommand. Users and automation can
resolve `pane.id` from `prowl agents --json`, then call existing pane-oriented
commands.

## Output Semantics

`prowl agents` should expose detected agents, not the worktree-level task status
from `prowl list`.

Important distinction:

- `prowl list` currently reports `task.status` at worktree level as
  `running | idle | null`.
- `prowl agents` should report per-pane agent detection state as
  `working | blocked | done | idle`, plus the raw detector state.

The command should return only panes where an agent is currently detected or has
a retained Active Agents entry. Empty shells and ordinary non-agent commands
should not appear.

## JSON Schema Sketch

Schema version: `prowl.cli.agents.v1`

```json
{
  "count": 2,
  "agents": [
    {
      "id": "6E1A2A10-D99F-4E3F-920C-D93AA3C05764",
      "type": "codex",
      "name": "codex",
      "status": "blocked",
      "raw_state": "blocked",
      "last_changed_at": "2026-06-13T04:12:25Z",
      "project": {
        "name": "Prowl",
        "branch": "feature/cli-agents",
        "path": "/Users/onevcat/Sync/github/Prowl"
      },
      "worktree": {
        "id": "Prowl:/Users/onevcat/Sync/github/Prowl",
        "name": "feature/cli-agents",
        "path": "/Users/onevcat/Sync/github/Prowl",
        "root_path": "/Users/onevcat/Sync/github/Prowl",
        "kind": "git"
      },
      "tab": {
        "id": "2FC00CF0-3974-4E1B-BEF8-7A08A8E3B7C0",
        "title": "issue 330",
        "selected": true
      },
      "pane": {
        "id": "6E1A2A10-D99F-4E3F-920C-D93AA3C05764",
        "index": 1,
        "title": "codex",
        "cwd": "/Users/onevcat/Sync/github/Prowl",
        "focused": false
      }
    }
  ]
}
```

Notes:

- `id` should equal `pane.id` / `surfaceID`, matching Active Agents entries.
- `type` should be the normalized `DetectedAgent.rawValue`.
- `name` should be `ActiveAgentEntry.displayName`, preserving command aliases
  such as `omp`.
- `status` should be `ActiveAgentEntry.displayState.rawValue`.
- `raw_state` should be `ActiveAgentEntry.rawState.rawValue`.
- `last_changed_at` should use ISO-8601.

## Project vs Owning Worktree

An agent may run in a different directory than the worktree that owns its
terminal pane. The CLI should expose both:

- `project`: display-oriented repository/branch resolved from
  `ActiveAgentEntry.workingDirectory`, using the same rules as the Active Agents
  panel (`SidebarListView.activeAgentRowDisplay`).
- `worktree`: the actual terminal owner, used for focus/read/send targeting.

This prevents automation from losing the concrete pane while still showing the
human-facing project label users expect.

## Text Rendering

Default text output should optimize for scanability:

```text
Blocked  codex   Prowl:feature/cli-agents  issue 330  6E1A2A10-D99F-4E3F-920C-D93AA3C05764
Working  claude  Notes:main                review     EF65FF31-1B72-40B2-80DA-3AA87B7B6858
```

Suggested ordering:

1. `blocked`
2. `working`
3. `done`
4. `idle`

Within each status group, preserve Active Agents insertion order unless a later
UX pass finds a better sort.

## Implementation Plan

1. Add shared CLI input/payload models:
   - `AgentsInput`
   - `AgentsCommandPayload`
   - `AgentsCommandAgent`
   - nested `project`, `worktree`, `tab`, and `pane` payload structs
2. Add `Command.agents(AgentsInput)` and route it through `CLICommandRouter`.
3. Add `AgentsCommandHandler`.
   - Snapshot source: `appStore.state.repositories.activeAgents.entries`
   - Repository metadata: reuse `SidebarListView.activeAgentWorktreeMetadata`
     and `SidebarListView.activeAgentRowDisplay`.
   - Terminal metadata: reuse existing target/list snapshot builders where
     possible to resolve tab selected state, pane title, cwd, and focus.
4. Add `ProwlCLI/Commands/AgentsCommand.swift` and register it in
   `ProwlCommand`.
5. Add text rendering in `OutputRenderer.renderAgents`.
6. Update `docs/components/cli.md` and `docs/components/active-agents.md`.

## Test Plan

- Command envelope round-trip for `agents`.
- Router dispatch test.
- Handler payload test covering:
  - status/raw state passthrough
  - alias display name (`omp` vs `pi`)
  - project label from `workingDirectory`
  - owning worktree/pane still present
  - focused pane marking
- CLI integration test for JSON output.
- CLI text rendering test for status ordering and empty state.

## Open Questions

- Whether `idle` agents should be included by default or hidden behind a flag.
  Initial recommendation: include them because the Active Agents panel includes
  retained idle/done entries, and automation can filter by status.
- Whether to add filtering flags such as `--status blocked` later. Initial
  recommendation: skip flags for v1; JSON + `jq` is enough.
