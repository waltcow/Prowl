import Foundation

enum GitOperation: String {
  case repoRoot = "repo_root"
  case worktreeList = "worktree_list"
  case worktreeCreate = "worktree_create"
  case worktreeRemove = "worktree_remove"
  case worktreePrune = "worktree_prune"
  case repoIsBare = "repo_is_bare"
  case branchNames = "branch_names"
  case branchNameValidation = "branch_name_validation"
  case branchRefs = "branch_refs"
  case defaultRemoteBranchRef = "default_remote_branch_ref"
  case localHeadRef = "local_head_ref"
  case ignoredFileCount = "ignored_file_count"
  case untrackedFileCount = "untracked_file_count"
  case branchRename = "branch_rename"
  case branchDelete = "branch_delete"
  case lineChanges = "line_changes"
  case diffNameStatus = "diff_name_status"
  case untrackedFilePaths = "untracked_file_paths"
  case showFile = "show_file"
  case remoteInfo = "remote_info"
  case remoteList = "remote_list"
  case fetchRemote = "fetch_remote"
}

enum GitClientError: LocalizedError {
  case commandFailed(command: String, message: String)

  var errorDescription: String? {
    switch self {
    case .commandFailed(let command, let message):
      if message.isEmpty {
        return "Git command failed: \(command)"
      }
      return "Git command failed: \(command)\n\(message)"
    }
  }
}

enum GitWorktreeCreateEvent: Equatable, Sendable {
  case outputLine(ShellStreamLine)
  case finished(Worktree)
}

enum LocalBranchDeletionOutcome: Equatable, Sendable {
  case deleted
  case notFound
  case protected
  case notRequested
}

nonisolated enum GitRemoteMatcher {
  static func matchingRemote(for ref: String, from remotes: [String]) -> String? {
    remotes
      .sorted { $0.count > $1.count }
      .first { ref.hasPrefix("\($0)/") }
  }
}

struct GitWtWorktreeEntry: Decodable, Equatable {
  let branch: String
  let path: String
  let head: String
  let isBare: Bool

  enum CodingKeys: String, CodingKey {
    case branch
    case path
    case head
    case isBare = "is_bare"
  }
}
