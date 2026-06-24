import ComposableArchitecture
import Foundation

@Reducer
struct WorktreeCreationPromptFeature {
  @ObservableState
  struct State: Equatable {
    let repositoryID: Repository.ID
    /// Canonical repository root, used to resolve relative path overrides in the
    /// preview the same way the reducer does (not reconstructed from the ID).
    let repositoryRootURL: URL
    let repositoryName: String
    let automaticBaseRef: String
    let baseRefOptions: [String]
    var branchName: String
    var selectedBaseRef: String?
    var fetchRemote: Bool
    /// Resolved default base directory, used to compute the location preview.
    let defaultWorktreeBaseDirectory: String
    /// Leaf folder name override; empty falls back to the branch name.
    var worktreeNameOverride: String = ""
    /// Parent directory override; empty falls back to `defaultWorktreeBaseDirectory`.
    var worktreePathOverride: String = ""
    /// Disclosure state for the advanced placement section. Collapsed by default.
    var showAdvancedOptions: Bool = false
    var validationMessage: String?
    var isValidating = false

    var automaticBaseRefLabel: String {
      automaticBaseRef.isEmpty ? "Automatic" : "Automatic (\(automaticBaseRef))"
    }

    /// Default leaf folder name shown as the name-override placeholder.
    var worktreeNamePlaceholder: String {
      branchName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Live validity of the current name override, so the footer can flag an
    /// invalid leaf instead of previewing a destination submit will reject.
    var worktreeNameValidationError: String? {
      WorktreePlacementOverride.nameValidationError(worktreeNameOverride)
    }

    /// Full destination path the worktree will be created at, mirroring the
    /// reducer's resolution.
    var resolvedWorktreeLocationPreview: String {
      SupacodePaths.previewWorktreeDirectory(
        defaultBaseDirectory: URL(filePath: defaultWorktreeBaseDirectory, directoryHint: .isDirectory),
        repositoryRootURL: repositoryRootURL,
        nameOverride: worktreeNameOverride,
        pathOverride: worktreePathOverride,
        branchName: branchName
      )
      .path(percentEncoded: false)
    }
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case cancelButtonTapped
    case createButtonTapped
    case setValidationMessage(String?)
    case setValidating(Bool)
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case cancel
    case submit(
      repositoryID: Repository.ID,
      branchName: String,
      baseRef: String?,
      placement: WorktreePlacementOverride
    )
  }

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        state.validationMessage = nil
        return .none

      case .cancelButtonTapped:
        return .send(.delegate(.cancel))

      case .createButtonTapped:
        let trimmed = state.branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
          state.validationMessage = "Branch name required."
          return .none
        }
        guard !trimmed.contains(where: \.isWhitespace) else {
          state.validationMessage = "Branch names can't contain spaces."
          return .none
        }
        let nameOverride = state.worktreeNameOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if let nameError = WorktreePlacementOverride.nameValidationError(nameOverride) {
          state.validationMessage = nameError
          return .none
        }
        state.validationMessage = nil
        let pathOverride = state.worktreePathOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        return .send(
          .delegate(
            .submit(
              repositoryID: state.repositoryID,
              branchName: trimmed,
              baseRef: state.selectedBaseRef,
              placement: WorktreePlacementOverride(
                name: nameOverride.isEmpty ? nil : nameOverride,
                path: pathOverride.isEmpty ? nil : pathOverride
              )
            )
          )
        )

      case .setValidationMessage(let message):
        state.validationMessage = message
        return .none

      case .setValidating(let isValidating):
        state.isValidating = isValidating
        return .none

      case .delegate:
        return .none
      }
    }
  }
}
