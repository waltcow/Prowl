struct CommandPaletteSuggestions: Equatable {
  static let maxItems = 8

  let recent: [CommandPaletteItem]
  let suggested: [CommandPaletteItem]

  var allItems: [CommandPaletteItem] { recent + suggested }
  var isEmpty: Bool { recent.isEmpty && suggested.isEmpty }
}

struct CommandPaletteItem: Identifiable, Equatable {
  static let defaultPriorityTier = 100

  let id: String
  let title: String
  let subtitle: String?
  let kind: Kind
  let priorityTier: Int
  let category: Category
  let keywords: [String]
  let defaultSuggestion: Bool

  init(
    id: String,
    title: String,
    subtitle: String?,
    kind: Kind,
    category: Category,
    defaultSuggestion: Bool,
    keywords: [String] = [],
    priorityTier: Int = defaultPriorityTier
  ) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
    self.kind = kind
    self.category = category
    self.defaultSuggestion = defaultSuggestion
    self.keywords = keywords
    self.priorityTier = priorityTier
  }

  enum Kind: Equatable {
    case checkForUpdates
    case openRepository
    case worktreeSelect(Worktree.ID)
    case openSettings
    case newWorktree
    case removeWorktree(Worktree.ID, Repository.ID)
    case archiveWorktree(Worktree.ID, Repository.ID)
    case viewArchivedWorktrees
    case refreshWorktrees
    case jumpToLatestUnread
    case ghosttyCommand(String)
    case openPullRequest(Worktree.ID)
    case openRepositoryOnCodeHost(Worktree.ID)
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
    #if DEBUG
      case debugTestToast(RepositoriesFeature.StatusToast)
      case debugSimulateUpdateFound
    #endif
  }

  enum Category: String, CaseIterable, Equatable {
    case view
    case navigation
    case worktree
    case pullRequest
    case terminal
    case app
    #if DEBUG
      case debug
    #endif
  }

  var appShortcutCommandID: String? {
    switch kind {
    case .checkForUpdates:
      return AppShortcuts.CommandID.checkForUpdates
    case .openRepository:
      return AppShortcuts.CommandID.openRepository
    case .openSettings:
      return AppShortcuts.CommandID.openSettings
    case .newWorktree:
      return AppShortcuts.CommandID.newWorktree
    case .viewArchivedWorktrees:
      return AppShortcuts.CommandID.archivedWorktrees
    case .refreshWorktrees:
      return AppShortcuts.CommandID.refreshWorktrees
    case .jumpToLatestUnread:
      return AppShortcuts.CommandID.jumpToLatestUnread
    case .openPullRequest,
      .openRepositoryOnCodeHost:
      return AppShortcuts.CommandID.openPullRequest
    case .toggleLeftSidebar:
      return AppShortcuts.CommandID.toggleLeftSidebar
    case .toggleActiveAgentsPanel:
      return AppShortcuts.CommandID.toggleActiveAgentsPanel
    case .toggleCanvas:
      return AppShortcuts.CommandID.toggleCanvas
    case .toggleShelf:
      return AppShortcuts.CommandID.toggleShelf
    case .showDiff:
      return AppShortcuts.CommandID.showDiff
    case .ghosttyCommand,
      .markPullRequestReady,
      .mergePullRequest,
      .closePullRequest,
      .copyFailingJobURL,
      .copyCiFailureLogs,
      .rerunFailedJobs,
      .openFailingCheckDetails,
      .installCLI,
      .worktreeSelect,
      .removeWorktree,
      .archiveWorktree,
      .changeFocusedTabIcon:
      return nil
    #if DEBUG
      case .debugTestToast, .debugSimulateUpdateFound:
        return nil
    #endif
    }
  }

  func appShortcut(in resolvedKeybindings: ResolvedKeybindingMap) -> AppShortcut? {
    guard let commandID = appShortcutCommandID else { return nil }
    return AppShortcuts.resolvedShortcut(for: commandID, in: resolvedKeybindings)
  }

  func appShortcutLabel(in resolvedKeybindings: ResolvedKeybindingMap) -> String? {
    appShortcut(in: resolvedKeybindings)?.display
  }

  func appShortcutSymbols(in resolvedKeybindings: ResolvedKeybindingMap) -> [String]? {
    appShortcut(in: resolvedKeybindings)?.displaySymbols
  }
}
