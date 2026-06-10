import ComposableArchitecture
import Foundation

extension RepositoriesFeature.State {
  var workspaceCreationCandidates: [ProjectWorkspaceCreationRepository] {
    repositories.compactMap { repository in
      guard !repository.isWorkspace, !removingRepositoryIDs.contains(repository.id) else {
        return nil
      }
      let name = repositoryCustomTitles[repository.id] ?? repository.name
      return ProjectWorkspaceCreationRepository(
        id: repository.id,
        name: name,
        rootURL: repository.rootURL
      )
    }
  }
}

nonisolated private let workspaceLog = SupaLogger("workspace")

nonisolated private struct WorkspaceBaseRefsResult: Sendable {
  var options: [GitBranchRefOption] = []
  var defaultBaseRef: String?
  var errorMessage: String?
}

extension RepositoriesFeature {
  func reduceWorkspaceCreation(
    state: inout State,
    action: WorkspaceCreationAction
  ) -> Effect<Action> {
    switch action {
    case .promptRequested:
      let candidates = state.workspaceCreationCandidates
      let title = "Workspace"
      state.workspaceCreationPrompt = WorkspaceCreationPromptFeature.State(
        repositories: [],
        title: title,
        rootPath: defaultWorkspaceRootURL(title: title).path(percentEncoded: false),
        openedRepositoryCandidates: candidates
      )
      return .none

    case .promptCanceled, .promptDismissed:
      let wasCreating = state.workspaceCreationPrompt?.isCreating == true
      state.workspaceCreationPrompt = nil
      guard wasCreating else {
        return .cancel(id: CancelID.workspaceCreation)
      }
      return .merge(
        .cancel(id: CancelID.workspaceCreation),
        .send(.showToast(.warning("Workspace creation canceled")))
      )

    case .refreshBaseRefs(let repositoryID):
      guard let repository = state.workspaceCreationPrompt?.repositories[id: repositoryID] else {
        return .none
      }
      return workspaceBaseRefsEffect(for: [repository])

    case .baseRefsLoaded(
      let repositoryID, let sourceKind, let sourceLocation, let options, let defaultBaseRef, let errorMessage
    ):
      Self.applyLoadedBaseRefs(
        into: &state,
        repositoryID: repositoryID,
        sourceKind: sourceKind,
        sourceLocation: sourceLocation,
        result: WorkspaceBaseRefsResult(
          options: options,
          defaultBaseRef: defaultBaseRef,
          errorMessage: errorMessage
        )
      )
      return .none

    case .createWorkspace(let draft):
      state.workspaceCreationPrompt?.isCreating = true
      state.workspaceCreationPrompt?.validationMessage = nil
      let request = ProjectWorkspaceCreationRequest(draft: draft, createdAt: now)
      let gitRunner = Self.workspaceGitRunner(shellClient: shellClient)
      return .run { send in
        do {
          _ = try await ProjectWorkspace.create(request, gitRunner: gitRunner)
          await send(.workspaceCreation(.workspaceCreated(request.draft.rootURL)))
        } catch {
          guard !Task.isCancelled else {
            workspaceLog.warning("Workspace creation canceled, rollback finished")
            return
          }
          workspaceLog.warning("Workspace creation failed: \(error.localizedDescription)")
          await send(.workspaceCreation(.workspaceCreationFailed(error.localizedDescription)))
        }
      }
      .cancellable(id: CancelID.workspaceCreation, cancelInFlight: true)

    case .workspaceCreated(let rootURL):
      analyticsClient.capture("workspace_created", [String: Any]?.none)
      state.workspaceCreationPrompt = nil
      return .merge(
        .send(.showToast(.success("Workspace created"))),
        .send(.repositoryManagement(.openRepositories([rootURL])))
      )

    case .workspaceCreationFailed(let message):
      if state.workspaceCreationPrompt != nil {
        state.workspaceCreationPrompt?.isCreating = false
        state.workspaceCreationPrompt?.validationMessage = message
      } else {
        state.alert = messageAlert(title: "Unable to create workspace", message: message)
      }
      return .none
    }
  }

  var workspaceCreationReducer: some ReducerOf<Self> {
    Reduce { state, action in
      guard case .workspaceCreation(let action) = action else {
        return .none
      }
      return reduceWorkspaceCreation(state: &state, action: action)
    }
  }

  private func defaultWorkspaceRootURL(title: String) -> URL {
    let folderName = ProjectWorkspace.defaultWorkspaceFolderName(for: title)
    let baseURL = SupacodePaths.workspacesDirectory
    var candidateURL = baseURL.appending(path: folderName, directoryHint: .isDirectory)
    var suffix = 2
    while FileManager.default.fileExists(atPath: candidateURL.path(percentEncoded: false)) {
      candidateURL = baseURL.appending(path: "\(folderName)-\(suffix)", directoryHint: .isDirectory)
      suffix += 1
    }
    return candidateURL.standardizedFileURL
  }

  private static func trimmedNonEmpty(_ value: String?) -> String? {
    guard let value else {
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func applyLoadedBaseRefs(
    into state: inout State,
    repositoryID: Repository.ID,
    sourceKind: ProjectWorkspaceRepositorySourceKind,
    sourceLocation: String,
    result: WorkspaceBaseRefsResult
  ) {
    guard var repository = state.workspaceCreationPrompt?.repositories[id: repositoryID],
      repository.sourceKind == sourceKind,
      repository.sourceLocation == sourceLocation
    else {
      return
    }
    if let errorMessage = result.errorMessage {
      state.workspaceCreationPrompt?.validationMessage = errorMessage
    }
    let baseRef = trimmedNonEmpty(repository.baseRef)
    let baseRefOptions = ProjectWorkspaceCreationRepository.normalizedBaseRefOptions(result.options)
    repository.baseRefOptions = baseRefOptions
    if let baseRef, baseRefOptions.contains(where: { $0.ref == baseRef }) {
      repository.baseRef = baseRef
    } else {
      repository.baseRef = result.defaultBaseRef
    }
    state.workspaceCreationPrompt?.repositories[id: repositoryID] = repository
  }

  private static func workspaceGitRunner(shellClient: ShellClient) -> ProjectWorkspaceGitRunner {
    ProjectWorkspaceGitRunner { command in
      do {
        _ = try await shellClient.run(
          URL(fileURLWithPath: "/usr/bin/env"),
          ["git"] + command.arguments,
          command.currentDirectoryURL
        )
      } catch let error as ShellClientError {
        throw ProjectWorkspaceCreationError.gitCommandFailed(
          command: command.displayCommand,
          message: error.stderr.isEmpty ? error.stdout : error.stderr
        )
      } catch {
        throw error
      }
    }
  }

  private func workspaceBaseRefsEffect(for repositories: [ProjectWorkspaceCreationRepository]) -> Effect<Action> {
    guard !repositories.isEmpty else {
      return .none
    }
    let gitClient = gitClient
    return .run { send in
      for repository in repositories {
        let result = await Self.workspaceBaseRefs(for: repository, gitClient: gitClient)
        await send(
          .workspaceCreation(
            .baseRefsLoaded(
              repositoryID: repository.id,
              sourceKind: repository.sourceKind,
              sourceLocation: repository.sourceLocation,
              options: result.options,
              defaultBaseRef: result.defaultBaseRef,
              errorMessage: result.errorMessage
            )
          )
        )
      }
    }
  }

  private static func workspaceBaseRefs(
    for repository: ProjectWorkspaceCreationRepository,
    gitClient: GitClientDependency
  ) async -> WorkspaceBaseRefsResult {
    switch repository.sourceKind {
    case .remote:
      return WorkspaceBaseRefsResult()

    case .existingPath, .localRepository, .bareRepository:
      guard let sourceURL = repository.localSourceURL else {
        return WorkspaceBaseRefsResult()
      }

      let repositoryURL: URL
      if repository.sourceKind == .bareRepository {
        repositoryURL = sourceURL
      } else {
        repositoryURL = (try? await gitClient.repoRoot(sourceURL)) ?? sourceURL
      }

      let automaticBaseRef = await gitClient.automaticWorktreeBaseRef(repositoryURL)
      let refs: [GitBranchRefOption]
      var errorMessage: String?
      do {
        refs = try await gitClient.branchRefOptions(repositoryURL)
      } catch {
        refs = []
        let name = repository.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = name.isEmpty ? repositoryURL.lastPathComponent : name
        errorMessage = "Could not read branches for \(displayName): \(error.localizedDescription)"
        workspaceLog.warning(
          "Branch detection failed for \(repositoryURL.path(percentEncoded: false)): \(error)"
        )
      }
      let options = ProjectWorkspaceCreationRepository.baseRefOptions(
        automaticBaseRef: automaticBaseRef,
        options: refs
      )
      let defaultBaseRef =
        automaticBaseRef != nil || !refs.isEmpty
        ? ProjectWorkspaceCreationRepository.preferredBaseRef(
          automaticBaseRef: automaticBaseRef,
          options: options
        )
        : nil
      return WorkspaceBaseRefsResult(
        options: options,
        defaultBaseRef: defaultBaseRef,
        errorMessage: errorMessage
      )
    }
  }
}
