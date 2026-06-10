import ComposableArchitecture
import Foundation
import IdentifiedCollections

@Reducer
struct WorkspaceCreationPromptFeature {
  @ObservableState
  struct State: Equatable {
    var repositories: IdentifiedArrayOf<ProjectWorkspaceCreationRepository>
    var openedRepositoryCandidates: IdentifiedArrayOf<ProjectWorkspaceCreationRepository>
    var title: String
    var rootPath: String
    var selectedRepositoryIDs: Set<Repository.ID>
    var validationMessage: String?
    var isCreating = false
    var remoteRepositoryPrompt: RemoteRepositoryPromptState?

    var selectedRepositoryCount: Int {
      repositories.count
    }

    var selectedRepositories: [ProjectWorkspaceCreationRepository] {
      Array(repositories)
    }

    var availableOpenedRepositories: [ProjectWorkspaceCreationRepository] {
      openedRepositoryCandidates.filter { repositories[id: $0.id] == nil }
    }

    var rootPathPreview: String {
      PathPolicy.normalizePath(rootPath, resolvingSymlinks: false) ?? rootPath
    }

    init(
      repositories: [ProjectWorkspaceCreationRepository],
      title: String,
      rootPath: String,
      selectedRepositoryIDs: Set<Repository.ID>,
      openedRepositoryCandidates: [ProjectWorkspaceCreationRepository] = []
    ) {
      self.repositories = IdentifiedArray(repositories, uniquingIDsWith: { current, _ in current })
      self.openedRepositoryCandidates = IdentifiedArray(
        openedRepositoryCandidates,
        uniquingIDsWith: { current, _ in current }
      )
      self.title = title
      self.rootPath = rootPath
      self.selectedRepositoryIDs = selectedRepositoryIDs
    }
  }

  @ObservableState
  struct RemoteRepositoryPromptState: Equatable {
    var url = ""
    var name = ""
    var branchOptions: [GitBranchRefOption] = []
    var defaultBaseRef: String?
    var validationMessage: String?
    var isLoading = false

    var displayName: String {
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? "Remote Repository" : trimmed
    }
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case addBlankRepository(ProjectWorkspaceRepositorySourceKind)
    case addOpenedRepository(Repository.ID)
    case addRepositoryFromURL(ProjectWorkspaceRepositorySourceKind, String)
    case addRemoteButtonTapped
    case remoteRepositoryPromptURLChanged(String)
    case remoteRepositoryPromptNameChanged(String)
    case remoteRepositoryPromptLoadButtonTapped
    case remoteRepositoryPromptLoaded(String, GitRemoteBranchRefs)
    case remoteRepositoryPromptFailed(String)
    case remoteRepositoryPromptAddButtonTapped
    case remoteRepositoryPromptDismissed
    case removeRepository(Repository.ID)
    case repositorySelectionChanged(Repository.ID, Bool)
    case repositorySourceKindChanged(Repository.ID, ProjectWorkspaceRepositorySourceKind)
    case repositoryCheckoutModeChanged(Repository.ID, ProjectWorkspaceRepositoryCheckoutMode)
    case repositoryNameChanged(Repository.ID, String)
    case repositoryPathChanged(Repository.ID, String)
    case repositorySourceChosen(Repository.ID, String)
    case repositorySourceLocationChanged(Repository.ID, String)
    case repositoryBranchNameChanged(Repository.ID, String)
    case repositoryBaseRefChanged(Repository.ID, String)
    case rootPathChosen(String)
    case cancelButtonTapped
    case createButtonTapped
    case setCreating(Bool)
    case setValidationMessage(String?)
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case baseRefSourceChanged(Repository.ID)
    case cancel
    case submit(ProjectWorkspaceCreationDraft)
  }

  @Dependency(\.uuid) var uuid
  @Dependency(GitClientDependency.self) var gitClient

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        state.validationMessage = nil
        return .none

      case .addBlankRepository(let sourceKind):
        let id = uuid().uuidString
        state.repositories.append(
          ProjectWorkspaceCreationRepository(
            id: id,
            name: "",
            sourceKind: sourceKind,
            sourceLocation: ""
          )
        )
        state.selectedRepositoryIDs.insert(id)
        state.validationMessage = nil
        return .none

      case .addOpenedRepository(let repositoryID):
        guard let repository = state.openedRepositoryCandidates[id: repositoryID],
          state.repositories[id: repositoryID] == nil
        else {
          return .none
        }
        state.repositories.append(repository)
        state.selectedRepositoryIDs.insert(repositoryID)
        state.validationMessage = nil
        return .send(.delegate(.baseRefSourceChanged(repositoryID)))

      case .addRemoteButtonTapped:
        state.remoteRepositoryPrompt = RemoteRepositoryPromptState()
        state.validationMessage = nil
        return .none

      case .remoteRepositoryPromptURLChanged(let url):
        state.remoteRepositoryPrompt?.url = url
        state.remoteRepositoryPrompt?.validationMessage = nil
        state.remoteRepositoryPrompt?.branchOptions = []
        state.remoteRepositoryPrompt?.defaultBaseRef = nil
        if state.remoteRepositoryPrompt?.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
          state.remoteRepositoryPrompt?.name = Self.remoteRepositoryName(for: url)
        }
        return .none

      case .remoteRepositoryPromptNameChanged(let name):
        state.remoteRepositoryPrompt?.name = name
        state.remoteRepositoryPrompt?.validationMessage = nil
        return .none

      case .remoteRepositoryPromptLoadButtonTapped:
        guard var prompt = state.remoteRepositoryPrompt else {
          return .none
        }
        let url = prompt.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
          prompt.validationMessage = "Remote URL required."
          state.remoteRepositoryPrompt = prompt
          return .none
        }
        prompt.url = url
        if prompt.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          prompt.name = Self.remoteRepositoryName(for: url)
        }
        prompt.isLoading = true
        prompt.validationMessage = nil
        state.remoteRepositoryPrompt = prompt
        let gitClient = gitClient
        return .run { send in
          do {
            let refs = try await gitClient.remoteBranchRefs(url)
            await send(.remoteRepositoryPromptLoaded(url, refs))
          } catch {
            await send(.remoteRepositoryPromptFailed(error.localizedDescription))
          }
        }

      case .remoteRepositoryPromptLoaded(let url, let refs):
        guard var prompt = state.remoteRepositoryPrompt,
          prompt.url.trimmingCharacters(in: .whitespacesAndNewlines) == url
        else {
          return .none
        }
        let options = ProjectWorkspaceCreationRepository.normalizedBaseRefOptions(refs.options)
        prompt.isLoading = false
        prompt.branchOptions = options
        prompt.defaultBaseRef = ProjectWorkspaceCreationRepository.preferredBaseRef(
          automaticBaseRef: refs.defaultBaseRef,
          options: options
        )
        prompt.validationMessage = options.isEmpty ? "No remote branches found." : nil
        state.remoteRepositoryPrompt = prompt
        return .none

      case .remoteRepositoryPromptFailed(let message):
        state.remoteRepositoryPrompt?.isLoading = false
        state.remoteRepositoryPrompt?.validationMessage = message
        return .none

      case .remoteRepositoryPromptAddButtonTapped:
        guard let prompt = state.remoteRepositoryPrompt else {
          return .none
        }
        let url = prompt.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
          state.remoteRepositoryPrompt?.validationMessage = "Remote URL required."
          return .none
        }
        guard !prompt.branchOptions.isEmpty else {
          state.remoteRepositoryPrompt?.validationMessage = "Load remote branches before adding."
          return .none
        }
        let id = uuid().uuidString
        state.repositories.append(
          ProjectWorkspaceCreationRepository(
            id: id,
            name: prompt.displayName,
            sourceKind: .remote,
            sourceLocation: url,
            checkoutMode: .useExistingRef,
            baseRef: prompt.defaultBaseRef,
            baseRefOptions: prompt.branchOptions
          )
        )
        state.selectedRepositoryIDs.insert(id)
        state.remoteRepositoryPrompt = nil
        state.validationMessage = nil
        return .none

      case .remoteRepositoryPromptDismissed:
        state.remoteRepositoryPrompt = nil
        return .none

      case .addRepositoryFromURL(let sourceKind, let path):
        guard let rootPath = PathPolicy.normalizePath(path) else {
          state.validationMessage =
            ProjectWorkspaceCreationError.missingRepositorySource("repository").localizedDescription
          return .none
        }
        let url = URL(fileURLWithPath: rootPath).standardizedFileURL
        let id = uuid().uuidString
        state.repositories.append(
          ProjectWorkspaceCreationRepository(
            id: id,
            name: Repository.name(for: url),
            sourceKind: sourceKind,
            sourceLocation: rootPath
          )
        )
        state.selectedRepositoryIDs.insert(id)
        state.validationMessage = nil
        return .send(.delegate(.baseRefSourceChanged(id)))

      case .removeRepository(let repositoryID):
        state.repositories.remove(id: repositoryID)
        state.selectedRepositoryIDs.remove(repositoryID)
        state.validationMessage = nil
        return .none

      case .repositorySelectionChanged(let repositoryID, let isSelected):
        if isSelected {
          state.selectedRepositoryIDs.insert(repositoryID)
        } else {
          state.selectedRepositoryIDs.remove(repositoryID)
        }
        state.validationMessage = nil
        return .none

      case .repositoryCheckoutModeChanged(let repositoryID, let checkoutMode):
        guard var repository = state.repositories[id: repositoryID] else {
          return .none
        }
        repository.checkoutMode = checkoutMode
        state.repositories[id: repositoryID] = repository
        state.validationMessage = nil
        return .none

      case .repositorySourceKindChanged(let repositoryID, let sourceKind):
        guard var repository = state.repositories[id: repositoryID] else {
          return .none
        }
        repository.sourceKind = sourceKind
        repository.baseRef = nil
        repository.baseRefOptions = []
        if sourceKind == .remote {
          repository.sourceLocation = ""
        }
        state.repositories[id: repositoryID] = repository
        state.validationMessage = nil
        guard sourceKind != .remote, repository.localSourceURL != nil else {
          return .none
        }
        return .send(.delegate(.baseRefSourceChanged(repositoryID)))

      case .repositoryNameChanged(let repositoryID, let name):
        state.repositories[id: repositoryID]?.name = name
        state.validationMessage = nil
        return .none

      case .repositoryPathChanged(let repositoryID, let path):
        state.repositories[id: repositoryID]?.path = path
        state.validationMessage = nil
        return .none

      case .repositorySourceChosen(let repositoryID, let sourceLocation):
        guard let rootPath = PathPolicy.normalizePath(sourceLocation) else {
          state.validationMessage =
            ProjectWorkspaceCreationError.missingRepositorySource("repository").localizedDescription
          return .none
        }
        guard var repository = state.repositories[id: repositoryID] else {
          return .none
        }
        repository.sourceLocation = rootPath
        if repository.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          repository.name = Repository.name(for: URL(fileURLWithPath: rootPath))
        }
        repository.baseRef = nil
        repository.baseRefOptions = []
        state.repositories[id: repositoryID] = repository
        state.validationMessage = nil
        return .send(.delegate(.baseRefSourceChanged(repositoryID)))

      case .repositorySourceLocationChanged(let repositoryID, let sourceLocation):
        guard var repository = state.repositories[id: repositoryID] else {
          return .none
        }
        let sourceLocationChanged = repository.sourceLocation != sourceLocation
        repository.sourceLocation = sourceLocation
        if sourceLocationChanged {
          repository.baseRef = nil
          repository.baseRefOptions = []
        }
        state.repositories[id: repositoryID] = repository
        state.validationMessage = nil
        guard sourceLocationChanged, repository.sourceKind != .remote, repository.localSourceURL != nil else {
          return .none
        }
        return .send(.delegate(.baseRefSourceChanged(repositoryID)))

      case .repositoryBranchNameChanged(let repositoryID, let branchName):
        state.repositories[id: repositoryID]?.branchName = branchName
        state.validationMessage = nil
        return .none

      case .repositoryBaseRefChanged(let repositoryID, let baseRef):
        guard var repository = state.repositories[id: repositoryID] else {
          return .none
        }
        let trimmed = baseRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || repository.baseRefOptions.contains(where: { $0.ref == trimmed }) else {
          return .none
        }
        repository.baseRef = trimmed.isEmpty ? nil : trimmed
        state.repositories[id: repositoryID] = repository
        state.validationMessage = nil
        return .none

      case .rootPathChosen(let path):
        state.rootPath = path
        state.validationMessage = nil
        return .none

      case .cancelButtonTapped:
        return .send(.delegate(.cancel))

      case .createButtonTapped:
        let title = state.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
          state.validationMessage = ProjectWorkspaceCreationError.missingTitle.localizedDescription
          return .none
        }
        guard let rootPath = PathPolicy.normalizePath(state.rootPath, resolvingSymlinks: false) else {
          state.validationMessage = ProjectWorkspaceCreationError.missingPath.localizedDescription
          return .none
        }
        let repositories = state.selectedRepositories
        guard repositories.count >= 2 else {
          state.validationMessage = ProjectWorkspaceCreationError.notEnoughRepositories.localizedDescription
          return .none
        }
        for repository in repositories {
          let name = repository.name.trimmingCharacters(in: .whitespacesAndNewlines)
          let sourceLocation = repository.sourceLocation.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !sourceLocation.isEmpty else {
            let displayName = name.isEmpty ? "repository" : name
            state.validationMessage =
              ProjectWorkspaceCreationError.missingRepositorySource(displayName).localizedDescription
            return .none
          }
          if repository.checkoutMode == .createBranch,
            repository.sourceKind == .remote || repository.sourceKind == .bareRepository,
            repository.branchName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
          {
            let displayName = name.isEmpty ? "repository" : name
            state.validationMessage = "Branch name required for \(displayName)."
            return .none
          }
          if repository.checkoutMode == .useExistingRef,
            repository.baseRef?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
          {
            let displayName = name.isEmpty ? "repository" : name
            state.validationMessage = "Choose an existing branch for \(displayName)."
            return .none
          }
        }
        state.validationMessage = nil
        return .send(
          .delegate(
            .submit(
              ProjectWorkspaceCreationDraft(
                title: title,
                rootURL: URL(filePath: rootPath, directoryHint: .isDirectory),
                repositories: repositories
              )
            )
          )
        )

      case .setCreating(let isCreating):
        state.isCreating = isCreating
        return .none

      case .setValidationMessage(let message):
        state.validationMessage = message
        return .none

      case .delegate:
        return .none
      }
    }
  }

  private static func remoteRepositoryName(for remoteURL: String) -> String {
    let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !trimmed.isEmpty else {
      return ""
    }
    let separatorIndex = trimmed.lastIndex { $0 == "/" || $0 == ":" }
    let component =
      separatorIndex.map { String(trimmed[trimmed.index(after: $0)...]) }
      ?? trimmed
    return component.hasSuffix(".git") ? String(component.dropLast(4)) : component
  }
}
