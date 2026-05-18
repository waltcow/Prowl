import ComposableArchitecture
import Foundation
import Sharing

@Reducer
struct CommandPaletteFeature {
  @ObservableState
  struct State: Equatable {
    var isPresented = false
    var query = ""
    var selectedIndex: Int?
    var recencyByItemID: [CommandPaletteItem.ID: TimeInterval] = [:]
  }

  enum SelectionMove: Equatable {
    case upSelection
    case downSelection
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case setPresented(Bool)
    case togglePresented
    case activateItem(CommandPaletteItem)
    case updateSelection(itemsCount: Int)
    case resetSelection(itemsCount: Int)
    case moveSelection(SelectionMove, itemsCount: Int)
    case pruneRecency([CommandPaletteItem.ID])
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case selectWorktree(Worktree.ID)
    case checkForUpdates
    case openSettings
    case newWorktree
    case openRepository
    case removeWorktree(Worktree.ID, Repository.ID)
    case archiveWorktree(Worktree.ID, Repository.ID)
    case viewArchivedWorktrees
    case refreshWorktrees
    case jumpToLatestUnread
    case ghosttyCommand(String)
    case openPullRequest(Worktree.ID)
    case markPullRequestReady(Worktree.ID)
    case mergePullRequest(Worktree.ID)
    case closePullRequest(Worktree.ID)
    case copyFailingJobURL(Worktree.ID)
    case copyCiFailureLogs(Worktree.ID)
    case rerunFailedJobs(Worktree.ID)
    case openFailingCheckDetails(Worktree.ID)
    case installCLI
    case changeFocusedTabIcon(Worktree.ID)
    case toggleLeftSidebar
    case toggleActiveAgentsPanel
    case toggleCanvas
    case toggleShelf
    case showDiff
    case revealInFinder
    case copyPath
    case revealInSidebar
    case runScript
    case stopRunScript
    case togglePinWorktree(Worktree.ID, isCurrentlyPinned: Bool)
    case renameBranch
    case newTab
    case openRepositorySettings(Repository.ID)
    case runCustomCommand(Int)
    #if DEBUG
      case debugTestToast(RepositoriesFeature.StatusToast)
      case debugSimulateUpdateFound
    #endif
  }

  @Dependency(\.date.now) private var now

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .setPresented(let isPresented):
        state.isPresented = isPresented
        if isPresented {
          loadRecency(into: &state)
          state.selectedIndex = nil
        } else {
          state.query = ""
          state.selectedIndex = nil
        }
        return .none

      case .togglePresented:
        state.isPresented.toggle()
        if state.isPresented {
          loadRecency(into: &state)
          state.selectedIndex = nil
        } else {
          state.query = ""
          state.selectedIndex = nil
        }
        return .none

      case .activateItem(let item):
        state.isPresented = false
        state.query = ""
        state.selectedIndex = nil
        state.recencyByItemID[item.id] = now.timeIntervalSince1970
        saveRecency(state.recencyByItemID)
        return .send(.delegate(delegateAction(for: item.kind)))

      case .updateSelection(let itemsCount):
        if itemsCount == 0 {
          state.selectedIndex = nil
          return .none
        }
        if let selectedIndex = state.selectedIndex, selectedIndex >= itemsCount {
          state.selectedIndex = itemsCount - 1
        } else if state.selectedIndex == nil {
          state.selectedIndex = 0
        }
        return .none

      case .resetSelection(let itemsCount):
        state.selectedIndex = itemsCount == 0 ? nil : 0
        return .none

      case .moveSelection(let direction, let itemsCount):
        guard itemsCount > 0 else {
          state.selectedIndex = nil
          return .none
        }
        let maxIndex = itemsCount - 1
        switch direction {
        case .upSelection:
          if let selectedIndex = state.selectedIndex {
            state.selectedIndex = selectedIndex == 0 ? maxIndex : selectedIndex - 1
          } else {
            state.selectedIndex = maxIndex
          }
        case .downSelection:
          if let selectedIndex = state.selectedIndex {
            state.selectedIndex = selectedIndex == maxIndex ? 0 : selectedIndex + 1
          } else {
            state.selectedIndex = 0
          }
        }
        return .none

      case .pruneRecency(let ids):
        let idSet = Set(ids)
        let pruned = state.recencyByItemID.filter { idSet.contains($0.key) }
        guard pruned != state.recencyByItemID else { return .none }
        state.recencyByItemID = pruned
        saveRecency(pruned)
        return .none

      case .delegate:
        return .none
      }
    }
  }

  static func suggestions(
    items: [CommandPaletteItem],
    recencyByID: [CommandPaletteItem.ID: TimeInterval] = [:],
    now: Date = .now
  ) -> CommandPaletteSuggestions {
    let recencyScored: [(item: CommandPaletteItem, score: Double)] = items.compactMap { item in
      let score = commandPaletteRecencyScore(item, recencyByID: recencyByID, now: now)
      return score > 0 ? (item, score) : nil
    }
    let recent = Array(
      recencyScored
        .sorted { $0.score > $1.score }
        .prefix(CommandPaletteSuggestions.maxItems)
        .map(\.item)
    )

    let recentIDs = Set(recent.map(\.id))
    let suggestedCandidates = items.enumerated().compactMap { idx, item -> (item: CommandPaletteItem, idx: Int)? in
      guard item.defaultSuggestion, !recentIDs.contains(item.id) else { return nil }
      return (item, idx)
    }
    let suggested = Array(
      suggestedCandidates
        .sorted { left, right in
          if left.item.priorityTier != right.item.priorityTier {
            return left.item.priorityTier < right.item.priorityTier
          }
          return left.idx < right.idx
        }
        .prefix(CommandPaletteSuggestions.maxItems - recent.count)
        .map(\.item)
    )

    return CommandPaletteSuggestions(recent: recent, suggested: suggested)
  }

  static func filterItems(
    items: [CommandPaletteItem],
    query: String,
    recencyByID: [CommandPaletteItem.ID: TimeInterval] = [:],
    now: Date = .now
  ) -> [CommandPaletteItem] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return suggestions(items: items, recencyByID: recencyByID, now: now).allItems
    }
    let scorer = CommandPaletteFuzzyScorer(query: trimmed, recencyByID: recencyByID, now: now)
    return scorer.rankedItems(from: items)
  }

  static func commandPaletteItems(
    from repositories: RepositoriesFeature.State,
    customCommands: [UserCustomCommand] = [],
    runScriptStatusByWorktreeID: [Worktree.ID: Bool] = [:],
    ghosttyCommands: [GhosttyCommand] = []
  ) -> [CommandPaletteItem] {
    let showsNewWorktreeAction =
      repositories.repositories.isEmpty
      || repositories.repositories.contains { $0.capabilities.supportsWorktrees }
    var items = globalCommandItems(showsNewWorktreeAction: showsNewWorktreeAction)
    if repositories.selectedWorktreeID != nil {
      items.append(
        .appShortcut(
          id: CommandPaletteItemID.globalShowDiff,
          title: "Show Diff",
          category: .view,
          kind: .showDiff,
          keywords: ["diff", "changes", "git"]
        )
      )
      items.append(contentsOf: worktreeNavigationCommandItems())
      items.append(
        contentsOf: worktreeActionCommandItems(
          repositories: repositories,
          runScriptStatusByWorktreeID: runScriptStatusByWorktreeID
        )
      )
    }
    items.append(contentsOf: customCommandItems(customCommands))
    if let terminalWorktree = repositories.selectedTerminalWorktree {
      items.append(
        .appShortcut(
          id: CommandPaletteItemID.globalNewTab,
          title: "New Tab",
          category: .worktree,
          kind: .newTab,
          keywords: ["new", "tab", "terminal"]
        )
      )
      items.append(
        CommandPaletteItem(
          id: CommandPaletteItemID.changeFocusedTabIcon(terminalWorktree.id),
          title: "Change Tab Icon...",
          subtitle: terminalWorktree.name,
          kind: .changeFocusedTabIcon(terminalWorktree.id),
          category: .worktree,
          defaultSuggestion: false
        )
      )
      items.append(contentsOf: ghosttyCommandItems(ghosttyCommands))
    }
    if let repository = activeRepository(in: repositories) {
      items.append(
        CommandPaletteItem(
          id: CommandPaletteItemID.openRepositorySettings(repository.id),
          title: "Repo Settings",
          subtitle: repository.name,
          kind: .openRepositorySettings(repository.id),
          category: .app,
          defaultSuggestion: true,
          keywords: ["repo", "settings", "configure", "preferences"]
        )
      )
    }
    items.append(contentsOf: selectedCodeHostItems(from: repositories))
    #if DEBUG
      items.append(contentsOf: debugToastItems())
    #endif
    for row in repositories.orderedWorktreeRows() {
      guard !row.isPending, !row.isDeleting else { continue }
      let repositoryName = repositories.repositoryName(for: row.repositoryID) ?? "Repository"
      let title = "\(repositoryName) / \(row.name)"
      items.append(
        CommandPaletteItem(
          id: CommandPaletteItemID.worktreeSelect(row.id),
          title: title,
          subtitle: nil,
          kind: .worktreeSelect(row.id),
          category: .navigation,
          defaultSuggestion: false
        )
      )
    }
    return items
  }

  static func recencyRetentionIDs(
    from repositories: IdentifiedArrayOf<Repository>,
    customCommands: [UserCustomCommand] = []
  ) -> [CommandPaletteItem.ID] {
    var ids = CommandPaletteItemID.globalIDs
    ids.append(contentsOf: customCommands.map { CommandPaletteItemID.customCommand($0.id) })
    for repository in repositories {
      ids.append(contentsOf: CommandPaletteItemID.pullRequestIDs(repositoryID: repository.id))
      ids.append(CommandPaletteItemID.openRepositorySettings(repository.id))
      for worktree in repository.worktrees {
        ids.append(CommandPaletteItemID.worktreeSelect(worktree.id))
        ids.append(CommandPaletteItemID.changeFocusedTabIcon(worktree.id))
      }
    }
    return ids
  }
}

private func globalCommandItems(showsNewWorktreeAction: Bool) -> [CommandPaletteItem] {
  var items: [CommandPaletteItem] = [
    .appShortcut(
      id: CommandPaletteItemID.globalCheckForUpdates,
      title: "Check for Updates",
      category: .app,
      kind: .checkForUpdates,
      keywords: ["update", "version"]
    ),
    .appShortcut(
      id: CommandPaletteItemID.globalOpenSettings,
      title: "Open Settings",
      category: .app,
      kind: .openSettings,
      keywords: ["preferences", "config"]
    ),
    .appShortcut(
      id: CommandPaletteItemID.globalOpenRepository,
      title: "Open Repository",
      category: .app,
      kind: .openRepository,
      keywords: ["repo", "add repo"]
    ),
  ]
  if showsNewWorktreeAction {
    items.append(
      .appShortcut(
        id: CommandPaletteItemID.globalNewWorktree,
        title: "New Worktree",
        category: .worktree,
        kind: .newWorktree,
        keywords: ["worktree", "branch"]
      )
    )
  }
  items.append(
    .appShortcut(
      id: CommandPaletteItemID.globalRefreshWorktrees,
      title: "Refresh Worktrees",
      category: .worktree,
      kind: .refreshWorktrees,
      keywords: ["reload", "rescan"]
    )
  )
  items.append(
    .appShortcut(
      id: CommandPaletteItemID.globalJumpToLatestUnread,
      title: "Jump to Latest Unread",
      category: .navigation,
      kind: .jumpToLatestUnread,
      keywords: ["unread", "bell", "notification"]
    )
  )
  items.append(
    .appShortcut(
      id: CommandPaletteItemID.globalViewArchivedWorktrees,
      title: "View Archived Worktrees",
      category: .worktree,
      kind: .viewArchivedWorktrees,
      keywords: ["archive", "history"]
    )
  )
  items.append(
    .appShortcut(
      id: CommandPaletteItemID.globalInstallCLI,
      title: "Install Command Line Tool",
      category: .app,
      kind: .installCLI,
      keywords: ["cli", "command line", "terminal", "prowl"]
    )
  )
  items.append(contentsOf: viewToggleCommandItems())
  return items
}

private func worktreeActionCommandItems(
  repositories: RepositoriesFeature.State,
  runScriptStatusByWorktreeID: [Worktree.ID: Bool]
) -> [CommandPaletteItem] {
  guard let worktreeID = repositories.selectedWorktreeID else { return [] }
  var items: [CommandPaletteItem] = []
  let isRunScriptRunning = runScriptStatusByWorktreeID[worktreeID] ?? false
  if isRunScriptRunning {
    items.append(
      .appShortcut(
        id: CommandPaletteItemID.globalStopRunScript,
        title: "Stop Script",
        category: .worktree,
        kind: .stopRunScript,
        keywords: ["stop", "kill", "cancel", "script"]
      )
    )
  } else {
    items.append(
      .appShortcut(
        id: CommandPaletteItemID.globalRunScript,
        title: "Run Script",
        category: .worktree,
        kind: .runScript,
        keywords: ["run", "script", "execute"]
      )
    )
  }
  guard let row = repositories.selectedRow(for: worktreeID) else { return items }
  // Rename Branch works on any worktree (main included).
  items.append(
    .appShortcut(
      id: CommandPaletteItemID.globalRenameBranch,
      title: "Rename Branch",
      category: .worktree,
      kind: .renameBranch,
      keywords: ["rename", "branch", "name"]
    )
  )
  // Pin / Unpin / Delete only apply to non-main worktrees.
  guard !row.isMainWorktree else { return items }
  let pinTitle = row.isPinned ? "Unpin Worktree" : "Pin Worktree"
  let pinKeywords =
    row.isPinned ? ["unpin", "favorite"] : ["pin", "favorite", "top"]
  items.append(
    .appShortcut(
      id: CommandPaletteItemID.globalTogglePinWorktree,
      title: pinTitle,
      category: .worktree,
      kind: .togglePinWorktree(worktreeID, isCurrentlyPinned: row.isPinned),
      keywords: pinKeywords
    )
  )
  if let repositoryID = repositories.repositoryID(containing: worktreeID) {
    items.append(
      CommandPaletteItem(
        id: CommandPaletteItemID.globalDeleteWorktree,
        title: "Delete Worktree",
        subtitle: row.name,
        kind: .deleteWorktree(worktreeID, repositoryID),
        category: .worktree,
        defaultSuggestion: false,
        keywords: ["delete", "remove", "destroy"]
      )
    )
  }
  return items
}

/// Resolves the "active" repository for repo-scoped palette commands:
/// prefers an explicitly selected repo, then falls back to the repo that
/// owns the currently-selected worktree. Returns nil when nothing relevant
/// is selected (e.g., archived view, empty palette).
private func activeRepository(
  in repositories: RepositoriesFeature.State
) -> Repository? {
  if let repository = repositories.selectedRepository {
    return repository
  }
  guard let worktreeID = repositories.selectedWorktreeID,
    let repositoryID = repositories.repositoryID(containing: worktreeID)
  else {
    return nil
  }
  return repositories.repositories[id: repositoryID]
}

private func customCommandItems(_ commands: [UserCustomCommand]) -> [CommandPaletteItem] {
  commands.enumerated().compactMap { index, command in
    guard command.hasRunnableCommand else { return nil }
    return CommandPaletteItem(
      id: CommandPaletteItemID.customCommand(command.id),
      title: command.resolvedTitle,
      subtitle: customCommandSubtitle(for: command),
      kind: .runCustomCommand(
        index: index,
        commandID: command.id,
        systemImage: command.resolvedSystemImage
      ),
      category: .worktree,
      defaultSuggestion: false,
      keywords: ["custom", "command", "script"]
    )
  }
}

private func customCommandSubtitle(for command: UserCustomCommand) -> String {
  "Custom command in this repo · \(customCommandExecutionDescription(for: command))"
}

private func customCommandExecutionDescription(for command: UserCustomCommand) -> String {
  switch command.execution {
  case .shellScript:
    return "Opens in a new tab"
  case .terminalInput:
    return "Runs in the focused terminal"
  case .split:
    return "Opens in a new split (\(command.splitDirection.title.lowercased()))"
  }
}

private func worktreeNavigationCommandItems() -> [CommandPaletteItem] {
  [
    .appShortcut(
      id: CommandPaletteItemID.globalRevealInFinder,
      title: "Reveal in Finder",
      category: .navigation,
      kind: .revealInFinder,
      keywords: ["finder", "open", "show"]
    ),
    .appShortcut(
      id: CommandPaletteItemID.globalCopyPath,
      title: "Copy Path",
      category: .navigation,
      kind: .copyPath,
      keywords: ["copy", "path", "clipboard"]
    ),
    .appShortcut(
      id: CommandPaletteItemID.globalRevealInSidebar,
      title: "Reveal in Sidebar",
      category: .navigation,
      kind: .revealInSidebar,
      keywords: ["reveal", "locate", "find worktree"]
    ),
  ]
}

private func viewToggleCommandItems() -> [CommandPaletteItem] {
  [
    .appShortcut(
      id: CommandPaletteItemID.globalToggleLeftSidebar,
      title: "Toggle Sidebar",
      category: .view,
      kind: .toggleLeftSidebar,
      keywords: ["sidebar", "hide", "left panel"]
    ),
    .appShortcut(
      id: CommandPaletteItemID.globalToggleActiveAgentsPanel,
      title: "Toggle Active Agents Panel",
      category: .view,
      kind: .toggleActiveAgentsPanel,
      keywords: ["agents", "panel"]
    ),
    .appShortcut(
      id: CommandPaletteItemID.globalToggleCanvas,
      title: "Toggle Canvas",
      category: .view,
      kind: .toggleCanvas,
      keywords: ["canvas", "overview", "grid"]
    ),
    .appShortcut(
      id: CommandPaletteItemID.globalToggleShelf,
      title: "Toggle Shelf",
      category: .view,
      kind: .toggleShelf,
      keywords: ["shelf", "books"]
    ),
  ]
}

private func selectedCodeHostItems(
  from repositories: RepositoriesFeature.State
) -> [CommandPaletteItem] {
  guard
    let selectedWorktreeID = repositories.selectedWorktreeID,
    let repositoryID = repositories.repositoryID(containing: selectedWorktreeID),
    let repository = repositories.repositories[id: repositoryID]
  else {
    return []
  }

  let codeHost = repositories.codeHost(for: repositoryID)
  let pullRequest = repositories.worktreeInfo(for: selectedWorktreeID)?.pullRequest
  if repository.capabilities.supportsPullRequests,
    let pullRequest,
    pullRequest.number > 0,
    pullRequest.state.uppercased() != "CLOSED"
  {
    return pullRequestItems(
      pullRequest: pullRequest,
      worktreeID: selectedWorktreeID,
      repositoryID: repositoryID,
      codeHost: codeHost
    )
  }

  guard repository.capabilities.supportsCodeHost else {
    return []
  }

  return [
    CommandPaletteItem(
      id: CommandPaletteItemID.pullRequestOpen(repositoryID),
      title: "Open Repository on \(codeHost.displayName)",
      subtitle: repository.name,
      kind: .openRepositoryOnCodeHost(selectedWorktreeID),
      category: .pullRequest,
      defaultSuggestion: false,
      priorityTier: 2
    )
  ]
}

private func pullRequestItems(
  pullRequest: GithubPullRequest,
  worktreeID: Worktree.ID,
  repositoryID: Repository.ID,
  codeHost: CodeHost
) -> [CommandPaletteItem] {
  let isOpen = pullRequest.state.uppercased() == "OPEN"
  let mergeReadiness = PullRequestMergeReadiness(pullRequest: pullRequest)
  let breakdown = PullRequestCheckBreakdown(checks: pullRequest.statusCheckRollup?.checks ?? [])
  let canMerge = isOpen && !pullRequest.isDraft && !mergeReadiness.isBlocking

  var items: [CommandPaletteItem] = [
    CommandPaletteItem(
      id: CommandPaletteItemID.pullRequestOpen(repositoryID),
      title: "Open Pull Request on \(codeHost.displayName)",
      subtitle: pullRequest.title,
      kind: .openPullRequest(worktreeID),
      category: .pullRequest,
      defaultSuggestion: true,
      priorityTier: 2
    )
  ]

  if let readyItem = makeReadyPullRequestItem(
    pullRequest: pullRequest,
    repositoryID: repositoryID,
    worktreeID: worktreeID
  ) {
    items.append(readyItem)
  }

  items.append(
    contentsOf: makeFailingPullRequestItems(
      pullRequest: pullRequest,
      repositoryID: repositoryID,
      worktreeID: worktreeID
    )
  )

  if let mergeItem = makeMergePullRequestItem(
    canMerge: canMerge,
    breakdown: breakdown,
    repositoryID: repositoryID,
    worktreeID: worktreeID
  ) {
    items.append(mergeItem)
  }

  if let closeItem = makeClosePullRequestItem(
    isOpen: isOpen,
    repositoryID: repositoryID,
    worktreeID: worktreeID,
    pullRequestTitle: pullRequest.title
  ) {
    items.append(closeItem)
  }

  return items
}

private func makeReadyPullRequestItem(
  pullRequest: GithubPullRequest,
  repositoryID: Repository.ID,
  worktreeID: Worktree.ID
) -> CommandPaletteItem? {
  let isOpen = pullRequest.state.uppercased() == "OPEN"
  guard isOpen && pullRequest.isDraft else { return nil }
  return CommandPaletteItem(
    id: CommandPaletteItemID.pullRequestReady(repositoryID),
    title: "Mark PR Ready for Review",
    subtitle: pullRequest.title,
    kind: .markPullRequestReady(worktreeID),
    category: .pullRequest,
    defaultSuggestion: true,
    priorityTier: 0
  )
}

private func makeFailingPullRequestItems(
  pullRequest: GithubPullRequest,
  repositoryID: Repository.ID,
  worktreeID: Worktree.ID
) -> [CommandPaletteItem] {
  let isOpen = pullRequest.state.uppercased() == "OPEN"
  let checks = pullRequest.statusCheckRollup?.checks ?? []
  let hasFailingChecks = PullRequestCheckBreakdown(checks: checks).failed > 0
  guard isOpen && hasFailingChecks else { return [] }
  let hasFailingCheckWithDetails = checks.contains { $0.checkState == .failure && $0.detailsUrl != nil }
  let leadingTier = pullRequest.isDraft ? 1 : 0
  let followupTier = leadingTier + 1
  var failingItems: [CommandPaletteItem] = []
  if hasFailingCheckWithDetails {
    failingItems.append(
      CommandPaletteItem(
        id: CommandPaletteItemID.pullRequestCopyFailingJobURL(repositoryID),
        title: "Copy failing job URL",
        subtitle: pullRequest.title,
        kind: .copyFailingJobURL(worktreeID),
        category: .pullRequest,
        defaultSuggestion: true,
        priorityTier: leadingTier
      )
    )
  }
  failingItems.append(
    CommandPaletteItem(
      id: CommandPaletteItemID.pullRequestCopyCiLogs(repositoryID),
      title: "Copy CI Failure Logs",
      subtitle: pullRequest.title,
      kind: .copyCiFailureLogs(worktreeID),
      category: .pullRequest,
      defaultSuggestion: true,
      priorityTier: hasFailingCheckWithDetails ? followupTier : leadingTier
    )
  )
  failingItems.append(
    CommandPaletteItem(
      id: CommandPaletteItemID.pullRequestRerunFailedJobs(repositoryID),
      title: "Re-run Failed Jobs",
      subtitle: pullRequest.title,
      kind: .rerunFailedJobs(worktreeID),
      category: .pullRequest,
      defaultSuggestion: true,
      priorityTier: followupTier
    )
  )
  if hasFailingCheckWithDetails {
    failingItems.append(
      CommandPaletteItem(
        id: CommandPaletteItemID.pullRequestOpenFailingCheck(repositoryID),
        title: "Open Failing Check Details",
        subtitle: pullRequest.title,
        kind: .openFailingCheckDetails(worktreeID),
        category: .pullRequest,
        defaultSuggestion: true,
        priorityTier: followupTier
      )
    )
  }
  return failingItems
}

private func makeMergePullRequestItem(
  canMerge: Bool,
  breakdown: PullRequestCheckBreakdown,
  repositoryID: Repository.ID,
  worktreeID: Worktree.ID
) -> CommandPaletteItem? {
  guard canMerge else { return nil }
  let successfulChecks = breakdown.passed
  let successfulChecksLabel =
    successfulChecks == 1
    ? "1 successful check"
    : "\(successfulChecks) successful checks"
  return CommandPaletteItem(
    id: CommandPaletteItemID.pullRequestMerge(repositoryID),
    title: "Merge PR",
    subtitle: "Merge Ready - \(successfulChecksLabel)",
    kind: .mergePullRequest(worktreeID),
    category: .pullRequest,
    defaultSuggestion: true,
    priorityTier: 0
  )
}

private func makeClosePullRequestItem(
  isOpen: Bool,
  repositoryID: Repository.ID,
  worktreeID: Worktree.ID,
  pullRequestTitle: String
) -> CommandPaletteItem? {
  guard isOpen else { return nil }
  return CommandPaletteItem(
    id: CommandPaletteItemID.pullRequestClose(repositoryID),
    title: "Close PR",
    subtitle: pullRequestTitle,
    kind: .closePullRequest(worktreeID),
    category: .pullRequest,
    defaultSuggestion: true,
    priorityTier: 1
  )
}

#if DEBUG
  private func debugToastItems() -> [CommandPaletteItem] {
    [
      CommandPaletteItem(
        id: "debug.toast.inProgress",
        title: "[Debug] Toast: In Progress",
        subtitle: "Simulates an in-progress toast",
        kind: .debugTestToast(.inProgress("Merging pull request…")),
        category: .debug,
        defaultSuggestion: true
      ),
      CommandPaletteItem(
        id: "debug.toast.success",
        title: "[Debug] Toast: Success",
        subtitle: "Simulates a success toast",
        kind: .debugTestToast(.success("Pull request merged")),
        category: .debug,
        defaultSuggestion: true
      ),
      CommandPaletteItem(
        id: "debug.update.simulate-found",
        title: "[Debug] Simulate Update Found",
        subtitle: "Shows the toolbar update badge without querying Sparkle",
        kind: .debugSimulateUpdateFound,
        category: .debug,
        defaultSuggestion: true
      ),
    ]
  }
#endif

private enum CommandPaletteItemID {
  static let ghosttyPrefix = "ghostty."
  static let globalCheckForUpdates = "global.check-for-updates"
  static let globalOpenSettings = "global.open-settings"
  static let globalOpenRepository = "global.open-repository"
  static let globalNewWorktree = "global.new-worktree"
  static let globalRefreshWorktrees = "global.refresh-worktrees"
  static let globalJumpToLatestUnread = "global.jump-to-latest-unread"
  static let globalViewArchivedWorktrees = "global.view-archived-worktrees"
  static let globalInstallCLI = "global.install-cli"
  static let globalToggleLeftSidebar = "global.toggle-left-sidebar"
  static let globalToggleActiveAgentsPanel = "global.toggle-active-agents-panel"
  static let globalToggleCanvas = "global.toggle-canvas"
  static let globalToggleShelf = "global.toggle-shelf"
  static let globalShowDiff = "global.show-diff"
  static let globalRevealInFinder = "global.reveal-in-finder"
  static let globalCopyPath = "global.copy-path"
  static let globalRevealInSidebar = "global.reveal-in-sidebar"
  static let globalRunScript = "global.run-script"
  static let globalStopRunScript = "global.stop-run-script"
  static let globalTogglePinWorktree = "global.toggle-pin-worktree"
  static let globalRenameBranch = "global.rename-branch"
  static let globalDeleteWorktree = "global.delete-worktree"
  static let globalNewTab = "global.new-tab"

  static func openRepositorySettings(_ repositoryID: Repository.ID) -> CommandPaletteItem.ID {
    "repo.\(repositoryID).open-settings"
  }

  static func customCommand(_ commandID: String) -> CommandPaletteItem.ID {
    "custom-command.\(commandID)"
  }

  static var globalIDs: [CommandPaletteItem.ID] {
    [
      globalCheckForUpdates,
      globalOpenSettings,
      globalOpenRepository,
      globalNewWorktree,
      globalRefreshWorktrees,
      globalJumpToLatestUnread,
      globalViewArchivedWorktrees,
      globalInstallCLI,
      globalToggleLeftSidebar,
      globalToggleActiveAgentsPanel,
      globalToggleCanvas,
      globalToggleShelf,
      globalShowDiff,
      globalRevealInFinder,
      globalCopyPath,
      globalRevealInSidebar,
      globalRunScript,
      globalStopRunScript,
      globalTogglePinWorktree,
      globalRenameBranch,
      globalDeleteWorktree,
      globalNewTab,
    ]
  }

  static func worktreeSelect(_ worktreeID: Worktree.ID) -> CommandPaletteItem.ID {
    "worktree.\(worktreeID).select"
  }

  static func changeFocusedTabIcon(_ worktreeID: Worktree.ID) -> CommandPaletteItem.ID {
    "terminal.\(worktreeID).change-focused-tab-icon"
  }

  static func ghosttyCommand(_ command: GhosttyCommand) -> CommandPaletteItem.ID {
    "\(ghosttyPrefix)\(command.action)|\(command.title)"
  }

  static func pullRequestIDs(repositoryID: Repository.ID) -> [CommandPaletteItem.ID] {
    [
      pullRequestOpen(repositoryID),
      pullRequestReady(repositoryID),
      pullRequestCopyFailingJobURL(repositoryID),
      pullRequestCopyCiLogs(repositoryID),
      pullRequestRerunFailedJobs(repositoryID),
      pullRequestOpenFailingCheck(repositoryID),
      pullRequestMerge(repositoryID),
      pullRequestClose(repositoryID),
    ]
  }

  static func pullRequestOpen(_ repositoryID: Repository.ID) -> CommandPaletteItem.ID {
    "pr.\(repositoryID).open"
  }

  static func pullRequestReady(_ repositoryID: Repository.ID) -> CommandPaletteItem.ID {
    "pr.\(repositoryID).ready"
  }

  static func pullRequestCopyFailingJobURL(_ repositoryID: Repository.ID) -> CommandPaletteItem.ID {
    "pr.\(repositoryID).copy-failing-job-url"
  }

  static func pullRequestCopyCiLogs(_ repositoryID: Repository.ID) -> CommandPaletteItem.ID {
    "pr.\(repositoryID).copy-ci-logs"
  }

  static func pullRequestRerunFailedJobs(_ repositoryID: Repository.ID) -> CommandPaletteItem.ID {
    "pr.\(repositoryID).rerun-failed-jobs"
  }

  static func pullRequestOpenFailingCheck(_ repositoryID: Repository.ID) -> CommandPaletteItem.ID {
    "pr.\(repositoryID).open-failing-check"
  }

  static func pullRequestMerge(_ repositoryID: Repository.ID) -> CommandPaletteItem.ID {
    "pr.\(repositoryID).merge"
  }

  static func pullRequestClose(_ repositoryID: Repository.ID) -> CommandPaletteItem.ID {
    "pr.\(repositoryID).close"
  }
}

private func commandPaletteRecencyScore(
  _ item: CommandPaletteItem,
  recencyByID: [CommandPaletteItem.ID: TimeInterval],
  now: Date
) -> Double {
  guard let lastActivated = recencyByID[item.id] else { return 0 }
  let ageSeconds = max(0, now.timeIntervalSince1970 - lastActivated)
  let ageDays = ageSeconds / 86_400
  let cappedAgeDays = min(ageDays, 30)
  return pow(0.5, cappedAgeDays / 7)
}

private func delegateAction(for kind: CommandPaletteItem.Kind) -> CommandPaletteFeature.Delegate {
  if let appAction = appDelegateAction(for: kind) {
    return appAction
  }
  switch kind {
  case .worktreeSelect(let id):
    return .selectWorktree(id)
  case .removeWorktree(let worktreeID, let repositoryID),
    .deleteWorktree(let worktreeID, let repositoryID):
    return .removeWorktree(worktreeID, repositoryID)
  case .archiveWorktree(let worktreeID, let repositoryID):
    return .archiveWorktree(worktreeID, repositoryID)
  case .ghosttyCommand(let action):
    return .ghosttyCommand(action)
  case .changeFocusedTabIcon(let worktreeID):
    return .changeFocusedTabIcon(worktreeID)
  case .togglePinWorktree(let worktreeID, let isCurrentlyPinned):
    return .togglePinWorktree(worktreeID, isCurrentlyPinned: isCurrentlyPinned)
  case .openRepositorySettings(let repositoryID):
    return .openRepositorySettings(repositoryID)
  case .runCustomCommand(let index, _, _):
    return .runCustomCommand(index)
  case .openPullRequest,
    .openRepositoryOnCodeHost,
    .markPullRequestReady,
    .mergePullRequest,
    .closePullRequest,
    .copyFailingJobURL,
    .copyCiFailureLogs,
    .rerunFailedJobs,
    .openFailingCheckDetails:
    return pullRequestDelegateAction(for: kind)!
  #if DEBUG
    case .debugTestToast(let toast):
      return .debugTestToast(toast)
    case .debugSimulateUpdateFound:
      return .debugSimulateUpdateFound
  #endif
  case .checkForUpdates,
    .openSettings,
    .newWorktree,
    .openRepository,
    .viewArchivedWorktrees,
    .refreshWorktrees,
    .jumpToLatestUnread,
    .installCLI,
    .toggleLeftSidebar,
    .toggleActiveAgentsPanel,
    .toggleCanvas,
    .toggleShelf,
    .showDiff,
    .revealInFinder,
    .copyPath,
    .revealInSidebar,
    .runScript,
    .stopRunScript,
    .renameBranch,
    .newTab:
    fatalError("appDelegateAction should handle app-level command palette actions")
  }
}

private func appDelegateAction(for kind: CommandPaletteItem.Kind) -> CommandPaletteFeature.Delegate? {
  if let delegate = navigationDelegateAction(for: kind) {
    return delegate
  }
  if let delegate = viewDelegateAction(for: kind) {
    return delegate
  }
  switch kind {
  case .checkForUpdates:
    return .checkForUpdates
  case .openSettings:
    return .openSettings
  case .newWorktree:
    return .newWorktree
  case .openRepository:
    return .openRepository
  case .viewArchivedWorktrees:
    return .viewArchivedWorktrees
  case .refreshWorktrees:
    return .refreshWorktrees
  case .jumpToLatestUnread:
    return .jumpToLatestUnread
  case .installCLI:
    return .installCLI
  case .runScript:
    return .runScript
  case .stopRunScript:
    return .stopRunScript
  case .renameBranch:
    return .renameBranch
  case .newTab:
    return .newTab
  default:
    return nil
  }
}

private func navigationDelegateAction(for kind: CommandPaletteItem.Kind) -> CommandPaletteFeature.Delegate? {
  switch kind {
  case .revealInFinder:
    return .revealInFinder
  case .copyPath:
    return .copyPath
  case .revealInSidebar:
    return .revealInSidebar
  default:
    return nil
  }
}

private func viewDelegateAction(for kind: CommandPaletteItem.Kind) -> CommandPaletteFeature.Delegate? {
  switch kind {
  case .toggleLeftSidebar:
    return .toggleLeftSidebar
  case .toggleActiveAgentsPanel:
    return .toggleActiveAgentsPanel
  case .toggleCanvas:
    return .toggleCanvas
  case .toggleShelf:
    return .toggleShelf
  case .showDiff:
    return .showDiff
  default:
    return nil
  }
}

private func pullRequestDelegateAction(
  for kind: CommandPaletteItem.Kind
) -> CommandPaletteFeature.Delegate? {
  switch kind {
  case .openPullRequest(let worktreeID),
    .openRepositoryOnCodeHost(let worktreeID):
    return .openPullRequest(worktreeID)
  case .markPullRequestReady(let worktreeID):
    return .markPullRequestReady(worktreeID)
  case .mergePullRequest(let worktreeID):
    return .mergePullRequest(worktreeID)
  case .closePullRequest(let worktreeID):
    return .closePullRequest(worktreeID)
  case .copyFailingJobURL(let worktreeID):
    return .copyFailingJobURL(worktreeID)
  case .copyCiFailureLogs(let worktreeID):
    return .copyCiFailureLogs(worktreeID)
  case .rerunFailedJobs(let worktreeID):
    return .rerunFailedJobs(worktreeID)
  case .openFailingCheckDetails(let worktreeID):
    return .openFailingCheckDetails(worktreeID)
  case .worktreeSelect,
    .checkForUpdates,
    .openSettings,
    .newWorktree,
    .openRepository,
    .removeWorktree,
    .archiveWorktree,
    .viewArchivedWorktrees,
    .refreshWorktrees,
    .jumpToLatestUnread,
    .installCLI,
    .ghosttyCommand,
    .changeFocusedTabIcon,
    .toggleLeftSidebar,
    .toggleActiveAgentsPanel,
    .toggleCanvas,
    .toggleShelf,
    .showDiff,
    .revealInFinder,
    .copyPath,
    .revealInSidebar,
    .runScript,
    .stopRunScript,
    .togglePinWorktree,
    .renameBranch,
    .deleteWorktree,
    .newTab,
    .openRepositorySettings,
    .runCustomCommand:
    return nil
  #if DEBUG
    case .debugTestToast, .debugSimulateUpdateFound:
      return nil
  #endif
  }
}

/// Ghostty action keys that should be hidden from Prowl's command palette.
///
/// Includes:
/// - actions Prowl already exposes natively (`check_for_updates`)
/// - Ghostty actions intentionally unsupported by Prowl's architecture/platform
private let filteredGhosttyActionKeys: Set<String> = [
  "check_for_updates",
  "new_window",
  "close_all_windows",
  "goto_window",
  "toggle_tab_overview",
  "toggle_window_decorations",
  "inspector",
  "show_gtk_inspector",
  "show_on_screen_keyboard",
]

private func ghosttyCommandItems(_ commands: [GhosttyCommand]) -> [CommandPaletteItem] {
  commands.compactMap { command in
    guard !filteredGhosttyActionKeys.contains(command.actionKey) else { return nil }
    return .ghosttyCommand(command)
  }
}

extension CommandPaletteItem {
  /// Build a top-level command backed by an `AppShortcuts` hotkey. Defaults to
  /// `defaultSuggestion: true` (since these are the kinds of actions worth
  /// listing when the palette opens with no query) and uses no subtitle (the
  /// hotkey hint and title already do the work).
  static func appShortcut(
    id: String,
    title: String,
    category: Category,
    kind: Kind,
    keywords: [String] = [],
    priorityTier: Int = defaultPriorityTier
  ) -> CommandPaletteItem {
    CommandPaletteItem(
      id: id,
      title: title,
      subtitle: nil,
      kind: kind,
      category: category,
      defaultSuggestion: true,
      keywords: keywords,
      priorityTier: priorityTier
    )
  }

  /// Build an item wrapping a Ghostty command exposed via the runtime.
  /// Lives in `.terminal`, ranks below regular suggestions (priority +100),
  /// and is search-only (never surfaces on empty query).
  static func ghosttyCommand(_ command: GhosttyCommand) -> CommandPaletteItem {
    let subtitle = command.description.trimmingCharacters(in: .whitespacesAndNewlines)
    return CommandPaletteItem(
      id: CommandPaletteItemID.ghosttyCommand(command),
      title: command.title,
      subtitle: subtitle.isEmpty ? nil : subtitle,
      kind: .ghosttyCommand(command.action),
      category: .terminal,
      defaultSuggestion: false,
      priorityTier: CommandPaletteItem.defaultPriorityTier + 100
    )
  }
}

private func loadRecency(into state: inout CommandPaletteFeature.State) {
  @Shared(.appStorage("commandPaletteItemRecency")) var recency: [String: Double] = [:]
  state.recencyByItemID = recency
}

private func saveRecency(_ recencyByItemID: [CommandPaletteItem.ID: TimeInterval]) {
  @Shared(.appStorage("commandPaletteItemRecency")) var recency: [String: Double] = [:]
  $recency.withLock {
    $0 = recencyByItemID
  }
}

private struct CommandPaletteFuzzyScorer {
  private struct PreparedQueryPiece {
    let normalized: String
    let normalizedLowercase: String
    let expectContiguousMatch: Bool
  }

  private struct PreparedQuery {
    let piece: PreparedQueryPiece
    let values: [PreparedQueryPiece]?
  }

  private struct Match {
    var start: Int
    var end: Int
  }

  private struct ItemScore {
    var score: Int
    var labelMatch: [Match]?
    var descriptionMatch: [Match]?
  }

  private struct ScoredItem {
    let item: CommandPaletteItem
    let score: ItemScore
    let recencyScore: Double
    let index: Int
  }

  private static let labelPrefixScoreThreshold = 1 << 17
  private static let labelScoreThreshold = 1 << 16

  private let query: PreparedQuery
  private let allowNonContiguousMatches: Bool
  private let recencyByID: [CommandPaletteItem.ID: TimeInterval]
  private let now: Date

  init(
    query: String,
    recencyByID: [CommandPaletteItem.ID: TimeInterval],
    now: Date,
    allowNonContiguousMatches: Bool = true
  ) {
    self.query = Self.prepareQuery(query)
    self.allowNonContiguousMatches = allowNonContiguousMatches
    self.recencyByID = recencyByID
    self.now = now
  }

  func rankedItems(from items: [CommandPaletteItem]) -> [CommandPaletteItem] {
    let scoredItems = items.enumerated().compactMap { index, item in
      let score = scoreItem(item)
      return score.score > 0
        ? ScoredItem(
          item: item,
          score: score,
          recencyScore: recencyScore(for: item),
          index: index
        )
        : nil
    }
    let sorted = scoredItems.sorted { compare($0, $1) < 0 }
    return sorted.map(\.item)
  }

  private func scoreItem(_ item: CommandPaletteItem) -> ItemScore {
    guard !query.piece.normalized.isEmpty else {
      return ItemScore(score: 0, labelMatch: nil, descriptionMatch: nil)
    }

    if let values = query.values, !values.isEmpty {
      return scoreItemMultiple(
        label: item.title,
        description: item.subtitle,
        keywords: item.keywords,
        query: values
      )
    }

    return scoreItemForPiece(
      label: item.title,
      description: item.subtitle,
      keywords: item.keywords,
      query: query.piece
    )
  }

  private func scoreItemMultiple(
    label: String,
    description: String?,
    keywords: [String],
    query: [PreparedQueryPiece]
  ) -> ItemScore {
    var totalScore = 0
    var totalLabelMatches: [Match] = []
    var totalDescriptionMatches: [Match] = []

    for piece in query {
      let score = scoreItemForPiece(label: label, description: description, keywords: keywords, query: piece)
      if score.score == 0 {
        return ItemScore(score: 0, labelMatch: nil, descriptionMatch: nil)
      }
      totalScore += score.score
      if let labelMatch = score.labelMatch {
        totalLabelMatches.append(contentsOf: labelMatch)
      }
      if let descriptionMatch = score.descriptionMatch {
        totalDescriptionMatches.append(contentsOf: descriptionMatch)
      }
    }

    return ItemScore(
      score: totalScore,
      labelMatch: normalizeMatches(totalLabelMatches),
      descriptionMatch: normalizeMatches(totalDescriptionMatches)
    )
  }

  /// Score one query piece against the item's title (with description fallback)
  /// and each keyword. Keywords act as alternative labels — when one outscores
  /// the title path, we keep title-derived highlight positions so the UI never
  /// paints offsets that don't exist in the visible string.
  private func scoreItemForPiece(
    label: String,
    description: String?,
    keywords: [String],
    query: PreparedQueryPiece
  ) -> ItemScore {
    var best = scoreItemSingle(label: label, description: description, query: query)
    for keyword in keywords {
      let keywordScore = scoreItemSingle(label: keyword, description: nil, query: query)
      if keywordScore.score > best.score {
        best = ItemScore(
          score: keywordScore.score,
          labelMatch: best.labelMatch,
          descriptionMatch: best.descriptionMatch
        )
      }
    }
    return best
  }

  private func scoreItemSingle(
    label: String,
    description: String?,
    query: PreparedQueryPiece
  ) -> ItemScore {
    let (labelScore, labelPositions) = scoreFuzzy(
      target: label,
      query: query,
      allowNonContiguousMatches: allowNonContiguousMatches && !query.expectContiguousMatch
    )
    if labelScore > 0 {
      let labelPrefixMatch = matchesPrefix(query: query.normalizedLowercase, target: label)
      let baseScore: Int
      if let labelPrefixMatch {
        let prefixLengthBoost = Int(
          (Double(query.normalized.count) / Double(label.count) * 100).rounded()
        )
        baseScore = Self.labelPrefixScoreThreshold + prefixLengthBoost
        return ItemScore(
          score: baseScore + labelScore,
          labelMatch: labelPrefixMatch,
          descriptionMatch: nil
        )
      }
      baseScore = Self.labelScoreThreshold
      return ItemScore(
        score: baseScore + labelScore,
        labelMatch: createMatches(labelPositions),
        descriptionMatch: nil
      )
    }

    if let description {
      let descriptionPrefixLength = description.count
      let descriptionAndLabel = description + label
      let (labelDescriptionScore, labelDescriptionPositions) = scoreFuzzy(
        target: descriptionAndLabel,
        query: query,
        allowNonContiguousMatches: allowNonContiguousMatches && !query.expectContiguousMatch
      )
      if labelDescriptionScore > 0 {
        let labelDescriptionMatches = createMatches(labelDescriptionPositions)
        var labelMatch: [Match] = []
        var descriptionMatch: [Match] = []

        for match in labelDescriptionMatches {
          if match.start < descriptionPrefixLength && match.end > descriptionPrefixLength {
            labelMatch.append(Match(start: 0, end: match.end - descriptionPrefixLength))
            descriptionMatch.append(Match(start: match.start, end: descriptionPrefixLength))
          } else if match.start >= descriptionPrefixLength {
            labelMatch.append(
              Match(
                start: match.start - descriptionPrefixLength,
                end: match.end - descriptionPrefixLength
              )
            )
          } else {
            descriptionMatch.append(match)
          }
        }

        return ItemScore(
          score: labelDescriptionScore,
          labelMatch: labelMatch,
          descriptionMatch: descriptionMatch
        )
      }
    }

    return ItemScore(score: 0, labelMatch: nil, descriptionMatch: nil)
  }

  private func compare(_ itemA: ScoredItem, _ itemB: ScoredItem) -> Int {
    let scoreA = itemA.score.score
    let scoreB = itemB.score.score

    if scoreA > Self.labelScoreThreshold || scoreB > Self.labelScoreThreshold {
      if scoreA != scoreB {
        return scoreA > scoreB ? -1 : 1
      }
      if scoreA < Self.labelPrefixScoreThreshold && scoreB < Self.labelPrefixScoreThreshold {
        let comparedByMatchLength = compareByMatchLength(itemA.score.labelMatch, itemB.score.labelMatch)
        if comparedByMatchLength != 0 {
          return comparedByMatchLength
        }
      }
      let labelA = itemA.item.title
      let labelB = itemB.item.title
      if labelA.count != labelB.count {
        return labelA.count - labelB.count
      }
    }

    if scoreA != scoreB {
      return scoreA > scoreB ? -1 : 1
    }

    let itemAHasLabelMatches = !(itemA.score.labelMatch?.isEmpty ?? true)
    let itemBHasLabelMatches = !(itemB.score.labelMatch?.isEmpty ?? true)
    if itemAHasLabelMatches && !itemBHasLabelMatches {
      return -1
    }
    if itemBHasLabelMatches && !itemAHasLabelMatches {
      return 1
    }

    if let itemAMatchDistance = matchDistance(itemA),
      let itemBMatchDistance = matchDistance(itemB),
      itemAMatchDistance != itemBMatchDistance
    {
      return itemBMatchDistance > itemAMatchDistance ? -1 : 1
    }

    if itemA.item.priorityTier != itemB.item.priorityTier {
      return itemA.item.priorityTier < itemB.item.priorityTier ? -1 : 1
    }

    if itemA.recencyScore != itemB.recencyScore {
      return itemA.recencyScore > itemB.recencyScore ? -1 : 1
    }

    let fallback = fallbackCompare(itemA.item, itemB.item)
    if fallback != 0 {
      return fallback
    }

    return itemA.index - itemB.index
  }

  private func matchDistance(_ item: ScoredItem) -> Int? {
    var matchStart = -1
    var matchEnd = -1

    if let descriptionMatch = item.score.descriptionMatch, !descriptionMatch.isEmpty {
      matchStart = descriptionMatch[0].start
    } else if let labelMatch = item.score.labelMatch, !labelMatch.isEmpty {
      matchStart = labelMatch[0].start
    }

    if let labelMatch = item.score.labelMatch, !labelMatch.isEmpty {
      matchEnd = labelMatch[labelMatch.count - 1].end
      if let descriptionMatch = item.score.descriptionMatch,
        !descriptionMatch.isEmpty,
        let description = item.item.subtitle
      {
        matchEnd += description.count
      }
    } else if let descriptionMatch = item.score.descriptionMatch, !descriptionMatch.isEmpty {
      matchEnd = descriptionMatch[descriptionMatch.count - 1].end
    }

    guard matchStart != -1 else { return nil }
    return matchEnd - matchStart
  }

  private func compareByMatchLength(_ matchesA: [Match]?, _ matchesB: [Match]?) -> Int {
    guard let matchesA, let matchesB else { return 0 }
    if matchesA.isEmpty && matchesB.isEmpty {
      return 0
    }
    if matchesB.isEmpty {
      return -1
    }
    if matchesA.isEmpty {
      return 1
    }

    let matchLengthA = matchesA[matchesA.count - 1].end - matchesA[0].start
    let matchLengthB = matchesB[matchesB.count - 1].end - matchesB[0].start

    if matchLengthA == matchLengthB {
      return 0
    }
    return matchLengthB < matchLengthA ? 1 : -1
  }

  private func fallbackCompare(_ itemA: CommandPaletteItem, _ itemB: CommandPaletteItem) -> Int {
    let labelA = itemA.title
    let labelB = itemB.title
    let descriptionA = itemA.subtitle
    let descriptionB = itemB.subtitle

    let labelDescriptionALength = labelA.count + (descriptionA?.count ?? 0)
    let labelDescriptionBLength = labelB.count + (descriptionB?.count ?? 0)

    if labelDescriptionALength != labelDescriptionBLength {
      return labelDescriptionALength - labelDescriptionBLength
    }

    if labelA != labelB {
      return compareStrings(labelA, labelB)
    }

    if let descriptionA, let descriptionB, descriptionA != descriptionB {
      return compareStrings(descriptionA, descriptionB)
    }

    return 0
  }

  private func compareStrings(_ stringA: String, _ stringB: String) -> Int {
    switch stringA.localizedStandardCompare(stringB) {
    case .orderedAscending:
      return -1
    case .orderedDescending:
      return 1
    case .orderedSame:
      return 0
    }
  }

  private func recencyScore(for item: CommandPaletteItem) -> Double {
    commandPaletteRecencyScore(item, recencyByID: recencyByID, now: now)
  }

  private func scoreFuzzy(
    target: String,
    query: PreparedQueryPiece,
    allowNonContiguousMatches: Bool
  ) -> (Int, [Int]) {
    if target.isEmpty || query.normalized.isEmpty {
      return (0, [])
    }

    let targetChars = Array(target)
    let queryChars = Array(query.normalized)

    if targetChars.count < queryChars.count {
      return (0, [])
    }

    let targetLower = Array(target.lowercased())
    let queryLower = Array(query.normalizedLowercase)

    return doScoreFuzzy(
      query: queryChars,
      queryLower: queryLower,
      target: targetChars,
      targetLower: targetLower,
      allowNonContiguousMatches: allowNonContiguousMatches
    )
  }

  private func doScoreFuzzy(
    query: [Character],
    queryLower: [Character],
    target: [Character],
    targetLower: [Character],
    allowNonContiguousMatches: Bool
  ) -> (Int, [Int]) {
    let queryLength = query.count
    let targetLength = target.count
    let scores = Array(repeating: 0, count: queryLength * targetLength)
    var mutableScores = scores
    let matches = Array(repeating: 0, count: queryLength * targetLength)
    var mutableMatches = matches

    for queryIndex in 0..<queryLength {
      let queryIndexOffset = queryIndex * targetLength
      let queryIndexPreviousOffset = queryIndexOffset - targetLength
      let queryIndexGtNull = queryIndex > 0

      let queryCharAtIndex = query[queryIndex]
      let queryLowerCharAtIndex = queryLower[queryIndex]

      for targetIndex in 0..<targetLength {
        let targetIndexGtNull = targetIndex > 0

        let currentIndex = queryIndexOffset + targetIndex
        let leftIndex = currentIndex - 1
        let diagIndex = queryIndexPreviousOffset + targetIndex - 1

        let leftScore = targetIndexGtNull ? mutableScores[leftIndex] : 0
        let diagScore = queryIndexGtNull && targetIndexGtNull ? mutableScores[diagIndex] : 0

        let matchesSequenceLength =
          queryIndexGtNull && targetIndexGtNull ? mutableMatches[diagIndex] : 0

        let score: Int
        let scoreContext = CharScoreContext(
          queryChar: queryCharAtIndex,
          queryLowerChar: queryLowerCharAtIndex,
          target: target,
          targetLower: targetLower,
          targetIndex: targetIndex,
          matchesSequenceLength: matchesSequenceLength
        )
        if diagScore != 0 && queryIndexGtNull {
          score = computeCharScore(scoreContext)
        } else if queryIndexGtNull {
          score = 0
        } else {
          score = computeCharScore(scoreContext)
        }

        let isValidScore = score > 0 && diagScore + score >= leftScore

        if isValidScore
          && (allowNonContiguousMatches || queryIndexGtNull
            || startsWith(
              targetLower,
              queryLower,
              at: targetIndex
            ))
        {
          mutableMatches[currentIndex] = matchesSequenceLength + 1
          mutableScores[currentIndex] = diagScore + score
        } else {
          mutableMatches[currentIndex] = 0
          mutableScores[currentIndex] = leftScore
        }
      }
    }

    var positions: [Int] = []
    var queryIndex = queryLength - 1
    var targetIndex = targetLength - 1
    while queryIndex >= 0 && targetIndex >= 0 {
      let currentIndex = queryIndex * targetLength + targetIndex
      let match = mutableMatches[currentIndex]
      if match == 0 {
        targetIndex -= 1
      } else {
        positions.append(targetIndex)
        queryIndex -= 1
        targetIndex -= 1
      }
    }

    positions.reverse()
    let finalScore = mutableScores[queryLength * targetLength - 1]
    return (finalScore, positions)
  }

  private struct CharScoreContext {
    let queryChar: Character
    let queryLowerChar: Character
    let target: [Character]
    let targetLower: [Character]
    let targetIndex: Int
    let matchesSequenceLength: Int
  }

  private func computeCharScore(_ context: CharScoreContext) -> Int {
    if !considerAsEqual(context.queryLowerChar, context.targetLower[context.targetIndex]) {
      return 0
    }

    var score = 1

    if context.matchesSequenceLength > 0 {
      score += (min(context.matchesSequenceLength, 3) * 6)
      score += max(0, context.matchesSequenceLength - 3) * 3
    }

    if context.queryChar == context.target[context.targetIndex] {
      score += 1
    }

    if context.targetIndex == 0 {
      score += 8
    } else {
      let separatorBonus = scoreSeparatorAtPos(context.target[context.targetIndex - 1])
      if separatorBonus > 0 {
        score += separatorBonus
      } else if isUpper(context.target[context.targetIndex]) && context.matchesSequenceLength == 0 {
        score += 2
      }
    }

    return score
  }

  private func considerAsEqual(_ lhs: Character, _ rhs: Character) -> Bool {
    if lhs == rhs {
      return true
    }
    if lhs == "/" || lhs == "\\" {
      return rhs == "/" || rhs == "\\"
    }
    return false
  }

  private func scoreSeparatorAtPos(_ char: Character) -> Int {
    switch char {
    case "/", "\\":
      return 5
    case "_", "-", ".", " ", "'", "\"", ":":
      return 4
    default:
      return 0
    }
  }

  private func isUpper(_ char: Character) -> Bool {
    guard let scalar = String(char).unicodeScalars.first else { return false }
    return scalar.properties.isUppercase
  }

  private func startsWith(
    _ target: [Character],
    _ query: [Character],
    at index: Int
  ) -> Bool {
    guard index + query.count <= target.count else { return false }
    for queryIndex in 0..<query.count where target[index + queryIndex] != query[queryIndex] {
      return false
    }
    return true
  }

  private func createMatches(_ offsets: [Int]) -> [Match] {
    var matches: [Match] = []
    var lastMatch: Match?

    for position in offsets {
      if var lastMatch, lastMatch.end == position {
        lastMatch.end += 1
        matches[matches.count - 1] = lastMatch
      } else {
        let match = Match(start: position, end: position + 1)
        matches.append(match)
        lastMatch = match
      }
    }

    return matches
  }

  private func normalizeMatches(_ matches: [Match]) -> [Match]? {
    guard !matches.isEmpty else { return nil }

    let sortedMatches = matches.sorted { $0.start < $1.start }
    var normalizedMatches: [Match] = []
    var currentMatch: Match?

    for match in sortedMatches {
      if let existing = currentMatch, matchOverlaps(existing, match) {
        let merged = Match(
          start: min(existing.start, match.start),
          end: max(existing.end, match.end)
        )
        currentMatch = merged
        normalizedMatches[normalizedMatches.count - 1] = merged
      } else {
        currentMatch = match
        normalizedMatches.append(match)
      }
    }

    return normalizedMatches
  }

  private func matchOverlaps(_ matchA: Match, _ matchB: Match) -> Bool {
    if matchA.end < matchB.start {
      return false
    }
    if matchB.end < matchA.start {
      return false
    }
    return true
  }

  private func matchesPrefix(query: String, target: String) -> [Match]? {
    let targetLower = target.lowercased()
    guard targetLower.hasPrefix(query) else { return nil }
    return [Match(start: 0, end: query.count)]
  }

  private static func prepareQuery(_ original: String) -> PreparedQuery {
    let expectContiguousMatch = queryExpectsExactMatch(original)
    let normalized = normalizeQuery(original)
    let piece = PreparedQueryPiece(
      normalized: normalized.normalized,
      normalizedLowercase: normalized.normalizedLowercase,
      expectContiguousMatch: expectContiguousMatch
    )

    let splitPieces = original.split(separator: " ")
    var values: [PreparedQueryPiece] = []
    if splitPieces.count > 1 {
      for pieceValue in splitPieces {
        let value = String(pieceValue)
        let expectExactMatchPiece = queryExpectsExactMatch(value)
        let normalizedPiece = normalizeQuery(value)
        if normalizedPiece.normalized.isEmpty {
          continue
        }
        values.append(
          PreparedQueryPiece(
            normalized: normalizedPiece.normalized,
            normalizedLowercase: normalizedPiece.normalizedLowercase,
            expectContiguousMatch: expectExactMatchPiece
          )
        )
      }
    }

    return PreparedQuery(
      piece: piece,
      values: values.isEmpty ? nil : values
    )
  }

  private static func normalizeQuery(_ original: String) -> (normalized: String, normalizedLowercase: String) {
    var pathNormalized = String()
    pathNormalized.reserveCapacity(original.count)
    for char in original {
      if char == "\\" {
        pathNormalized.append("/")
      } else {
        pathNormalized.append(char)
      }
    }

    var normalized = String()
    normalized.reserveCapacity(pathNormalized.count)
    for char in pathNormalized {
      if char == "*" || char == "…" || char == "\"" || char.isWhitespace {
        continue
      }
      normalized.append(char)
    }

    if normalized.count > 1, normalized.hasSuffix("#") {
      normalized.removeLast()
    }

    return (normalized, normalized.lowercased())
  }

  private static func queryExpectsExactMatch(_ query: String) -> Bool {
    query.hasPrefix("\"") && query.hasSuffix("\"")
  }
}
