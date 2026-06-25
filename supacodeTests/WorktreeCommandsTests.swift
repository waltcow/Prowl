import Foundation
import IdentifiedCollections
import Testing

@testable import supacode

@MainActor
struct WorktreeCommandsTests {
  @Test func codeHostWorktreeIDUsesCanvasFocusedWorktreeInCanvasMode() {
    let rootPath = "/tmp/repo-canvas-command-code-host"
    let worktree = Self.makeWorktree(id: "\(rootPath)/wt-1", name: "feature/canvas", repoRoot: rootPath)
    let repository = Self.makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = SidebarSelection.canvas

    let result = codeHostWorktreeID(
      repositories: state,
      canvasFocusedWorktreeID: worktree.id
    )

    #expect(result == worktree.id)
  }

  @Test func codeHostWorktreeIDRequiresCodeHostSupport() {
    let repository = Repository(
      id: "/tmp/plain-folder-code-host",
      rootURL: URL(fileURLWithPath: "/tmp/plain-folder-code-host"),
      name: "Folder",
      kind: .plain,
      worktrees: []
    )
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = SidebarSelection.canvas

    let result = codeHostWorktreeID(
      repositories: state,
      canvasFocusedWorktreeID: repository.id
    )

    #expect(result == nil)
  }

  private static func makeWorktree(id: String, name: String, repoRoot: String) -> Worktree {
    Worktree(
      id: id,
      name: name,
      detail: id,
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: repoRoot)
    )
  }

  private static func makeRepository(rootPath: String, name: String, worktrees: [Worktree]) -> Repository {
    Repository(
      id: rootPath,
      rootURL: URL(fileURLWithPath: rootPath),
      name: name,
      worktrees: IdentifiedArray(uniqueElements: worktrees)
    )
  }
}
