import Foundation
import Testing

@testable import supacode

struct GitClientShellFallbackTests {
  private func shellError(
    stderr: String = "",
    stdout: String = "",
    exitCode: Int32 = 1
  ) -> ShellClientError {
    ShellClientError(command: "wt root", stdout: stdout, stderr: stderr, exitCode: exitCode)
  }

  // MARK: - Should fallback

  @Test func fallsBackWhenExecutableNotFound() {
    #expect(shouldFallbackToLoginShell(shellError(exitCode: 127)))
  }

  @Test func fallsBackOnCommandNotFoundMessage() {
    #expect(shouldFallbackToLoginShell(shellError(stderr: "env: git: command not found")))
  }

  @Test func fallsBackWhenXcodeLicenseUnaccepted() {
    let stderr = """
      You have not agreed to the Xcode license agreements. Please run 'sudo xcodebuild -license' \
      from within a Terminal window to review and agree to the Xcode and Apple SDKs license.
      """
    #expect(shouldFallbackToLoginShell(shellError(stderr: stderr, exitCode: 69)))
  }

  @Test func fallsBackOnInvalidActiveDeveloperPath() {
    let stderr = "xcode-select: error: invalid active developer path (/Library/Developer/CommandLineTools)"
    #expect(shouldFallbackToLoginShell(shellError(stderr: stderr, exitCode: 1)))
  }

  @Test func fallsBackOnUnknownShellError() {
    #expect(shouldFallbackToLoginShell(shellError(stderr: "something unexpected", exitCode: 42)))
  }

  @Test func fallsBackOnEmptyErrorOutput() {
    #expect(shouldFallbackToLoginShell(shellError(exitCode: 1)))
  }

  // MARK: - Should NOT fallback

  @Test func doesNotFallBackForGenuineNonGitDirectory() {
    #expect(
      shouldFallbackToLoginShell(
        shellError(stderr: "fatal: not a git repository (or any of the parent directories)", exitCode: 128)
      ) == false
    )
  }

  @Test func doesNotFallBackWhenWtReportsNotGitRepo() {
    #expect(
      shouldFallbackToLoginShell(
        shellError(stderr: "wt: not a git repository", exitCode: 1)
      ) == false
    )
  }

  @Test func doesNotFallBackForNonShellError() {
    struct OtherError: Error {}
    #expect(shouldFallbackToLoginShell(OtherError()) == false)
  }
}
