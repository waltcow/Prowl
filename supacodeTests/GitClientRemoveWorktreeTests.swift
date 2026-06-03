import Foundation
import Testing

@testable import supacode

struct GitClientRemoveWorktreeTests {
  @Test func removeWorktreeDoesNotDeleteMainBranch() async throws {
    let store = ShellCallStore()
    let worktreePath = FileManager.default.temporaryDirectory
      .appending(path: "prowl-repo-main-copy-\(UUID().uuidString)", directoryHint: .isDirectory)
      .path(percentEncoded: false)
    let shell = ShellClient(
      run: { _, arguments, _ in
        await store.record(arguments)
        if arguments.contains("--porcelain") {
          return ShellOutput(
            stdout: "worktree \(worktreePath)\nHEAD abc\nbranch refs/heads/main\n", stderr: "", exitCode: 0)
        }
        if arguments.contains("for-each-ref") {
          return ShellOutput(stdout: "main\nfeature\n", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)
    let worktree = Worktree(
      id: worktreePath,
      name: "main",
      detail: "../repo-main-copy",
      workingDirectory: URL(fileURLWithPath: worktreePath),
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
    let worktreePath = "/tmp/repo-feature"
    let shell = ShellClient(
      run: { _, arguments, _ in
        await store.record(arguments)
        if arguments.contains("--porcelain") {
          return ShellOutput(
            stdout: "worktree \(worktreePath)\nHEAD abc\nbranch refs/heads/feature\n",
            stderr: "",
            exitCode: 0
          )
        }
        if arguments.contains("for-each-ref") {
          return ShellOutput(stdout: "main\nfeature\n", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)
    let worktree = Worktree(
      id: worktreePath,
      name: "feature",
      detail: "../repo-feature",
      workingDirectory: URL(fileURLWithPath: worktreePath),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )

    _ = try await client.removeWorktree(worktree, deleteBranch: true)

    let calls = await store.calls
    #expect(calls.contains { $0.suffix(3) == ["branch", "-d", "feature"] })
  }

  @Test func removeWorktreeDoesNotMoveDirectoryWhenPathIsNotRegisteredExactly() async throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory.appending(
      path: "prowl-remove-worktree-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let parentURL = rootURL.appending(path: ".worktrees/feat", directoryHint: .isDirectory)
    let childURL = parentURL.appending(path: "foo", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: childURL, withIntermediateDirectories: true)
    try Data("gitdir: ../../.git/worktrees/foo\n".utf8).write(to: childURL.appending(path: ".git"))
    defer {
      try? fileManager.removeItem(at: rootURL)
    }

    let store = ShellCallStore()
    let shell = ShellClient(
      run: { _, arguments, _ in
        await store.record(arguments)
        if arguments.contains("--porcelain") {
          return ShellOutput(
            stdout: "worktree \(childURL.path(percentEncoded: false))\nHEAD abc\nbranch refs/heads/feat/foo\n",
            stderr: "",
            exitCode: 0
          )
        }
        if arguments.contains("for-each-ref") {
          return ShellOutput(stdout: "feat\nfeat/foo\n", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)
    let worktree = Worktree(
      id: parentURL.path(percentEncoded: false),
      name: "feat",
      detail: ".worktrees/feat",
      workingDirectory: parentURL,
      repositoryRootURL: rootURL
    )

    _ = try await client.removeWorktree(worktree, deleteBranch: true)

    let parentExists = fileManager.fileExists(atPath: parentURL.path(percentEncoded: false))
    let childExists = fileManager.fileExists(atPath: childURL.path(percentEncoded: false))
    #expect(parentExists)
    #expect(childExists)
    let calls = await store.calls
    #expect(!calls.contains { $0.contains("prune") })
    #expect(!calls.contains { $0.contains("remove") })
    #expect(!calls.contains { $0.suffix(3) == ["branch", "-d", "feat"] })
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
