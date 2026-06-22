import Foundation
import Sentry

nonisolated let gitLogger = SupaLogger("Git")

nonisolated func shouldFallbackToLoginShell(_ error: Error) -> Bool {
  guard let shellError = error as? ShellClientError else {
    return false
  }
  let output = "\(shellError.stderr)\n\(shellError.stdout)".lowercased()
  // When git itself ran fine but confirmed this isn't a repo, retrying
  // under a login shell won't change the answer.
  if output.contains("not a git repository") {
    return false
  }
  return true
}

nonisolated func wrapShellError(
  _ error: Error,
  operation: GitOperation,
  command: String
) -> GitClientError {
  let gitError: GitClientError
  var exitCode: Int32 = -1
  if let shellError = error as? ShellClientError {
    exitCode = shellError.exitCode
    var messageParts: [String] = []
    if !shellError.stdout.isEmpty {
      messageParts.append("stdout:\n\(shellError.stdout)")
    }
    if !shellError.stderr.isEmpty {
      messageParts.append("stderr:\n\(shellError.stderr)")
    }
    let message = messageParts.joined(separator: "\n")
    gitError = .commandFailed(command: command, message: message)
  } else {
    gitError = .commandFailed(command: command, message: error.localizedDescription)
  }
  gitLogger.warning("git command failed operation=\(operation.rawValue) exit_code=\(exitCode)")
  #if !DEBUG
    SentrySDK.logger.error(
      "git command failed",
      attributes: [
        "operation": operation.rawValue,
        "exit_code": Int(exitCode),
      ]
    )
  #endif
  return gitError
}
