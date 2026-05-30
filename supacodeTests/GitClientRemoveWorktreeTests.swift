import Foundation
import Testing

@testable import supacode

struct GitClientRemoveWorktreeTests {
  @Test func removeWorktreeDoesNotDeleteMainBranch() async throws {
    let store = ShellCallStore()
    let shell = ShellClient(
      run: { _, arguments, _ in
        await store.record(arguments)
        if arguments.contains("for-each-ref") {
          return ShellOutput(stdout: "main\nfeature\n", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)
    let worktree = Worktree(
      id: "/tmp/repo-main-copy",
      name: "main",
      detail: "../repo-main-copy",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo-main-copy"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )

    _ = try await client.removeWorktree(worktree, deleteBranch: true)

    let calls = await store.calls
    #expect(calls.contains { $0.contains("worktree") && $0.contains("remove") })
    #expect(calls.contains { $0.contains("for-each-ref") })
    #expect(!calls.contains { $0.suffix(3) == ["branch", "-d", "main"] })
    #expect(!calls.contains { $0.suffix(3) == ["branch", "-D", "main"] })
  }

  @Test func removeWorktreeDeletesNonProtectedLocalBranchWhenRequested() async throws {
    let store = ShellCallStore()
    let shell = ShellClient(
      run: { _, arguments, _ in
        await store.record(arguments)
        if arguments.contains("for-each-ref") {
          return ShellOutput(stdout: "main\nfeature\n", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)
    let worktree = Worktree(
      id: "/tmp/repo-feature",
      name: "feature",
      detail: "../repo-feature",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo-feature"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )

    _ = try await client.removeWorktree(worktree, deleteBranch: true)

    let calls = await store.calls
    #expect(calls.contains { $0.suffix(3) == ["branch", "-d", "feature"] })
  }

  @Test func forceDeleteLocalBranchUsesForceFlag() async throws {
    let store = ShellCallStore()
    let shell = ShellClient(
      run: { _, arguments, _ in
        await store.record(arguments)
        if arguments.contains("for-each-ref") {
          return ShellOutput(stdout: "feature\n", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let outcome = try await client.deleteLocalBranch(
      named: "feature",
      for: URL(fileURLWithPath: "/tmp/repo"),
      force: true
    )

    #expect(outcome == .deleted)
    let calls = await store.calls
    #expect(calls.contains { $0.suffix(3) == ["branch", "-D", "feature"] })
  }

  @Test func safeDeleteLocalBranchPropagatesGitFailure() async {
    let shell = ShellClient(
      run: { _, arguments, _ in
        if arguments.contains("for-each-ref") {
          return ShellOutput(stdout: "feature\n", stderr: "", exitCode: 0)
        }
        throw ShellClientError(command: "git branch -d feature", stdout: "", stderr: "not fully merged", exitCode: 1)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    await #expect(throws: GitClientError.self) {
      _ = try await client.deleteLocalBranch(
        named: "feature",
        for: URL(fileURLWithPath: "/tmp/repo"),
        force: false
      )
    }
  }
}
