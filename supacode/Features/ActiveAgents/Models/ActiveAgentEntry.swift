import Foundation

struct ActiveAgentEntry: Identifiable, Equatable, Sendable {
  let id: UUID
  /// The worktree that physically owns the agent's terminal surface (the tab's worktree).
  /// Drives navigation/focus (`focusSurface`/`selectWorktree`), so it must stay the surface's
  /// real owner even when the agent runs in a different directory. Display name/branch come from
  /// `workingDirectory` instead — see `SidebarListView.activeAgentRowDisplay`.
  let worktreeID: Worktree.ID
  let worktreeName: String
  /// The agent's current working directory at detection time, used to resolve the displayed
  /// repository/branch. `nil` when the terminal hasn't reported a directory, in which case the
  /// display falls back to `worktreeID`/`worktreeName`.
  let workingDirectory: URL?
  let tabID: TerminalTabID
  let tabTitle: String
  let surfaceID: UUID
  let paneIndex: Int
  /// Command/process token used for row icon lookup. This can be more specific than
  /// `agent` for aliases that share one semantic agent, e.g. `omp` vs `pi`.
  let iconLookupToken: String
  let agent: DetectedAgent
  let rawState: AgentRawState
  let displayState: AgentDisplayState
  let lastChangedAt: Date
  var displayName: String {
    let trimmed = iconLookupToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !trimmed.isEmpty,
      trimmed != "agent",
      CommandIconMap.iconForFirstToken(trimmed) != nil
    else {
      return agent.displayName
    }
    return trimmed
  }

  var iconSource: TabIconSource? {
    CommandIconMap.iconForFirstToken(iconLookupToken) ?? CommandIconMap.iconForFirstToken(agent.iconLookupToken)
  }
}
