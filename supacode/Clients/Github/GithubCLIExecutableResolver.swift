import Foundation

actor GithubCLIExecutableResolver {
  private var cachedExecutableURL: URL?
  private var inFlightResolution: Task<URL, Error>?

  func executableURL(shell: ShellClient) async throws -> URL {
    if let cachedExecutableURL {
      return cachedExecutableURL
    }
    if let inFlightResolution {
      return try await inFlightResolution.value
    }
    let resolutionTask = Task {
      try await resolveExecutableURL(shell: shell)
    }
    inFlightResolution = resolutionTask
    do {
      let executableURL = try await resolutionTask.value
      cachedExecutableURL = executableURL
      inFlightResolution = nil
      return executableURL
    } catch {
      inFlightResolution = nil
      throw error
    }
  }

  func invalidate() {
    cachedExecutableURL = nil
    inFlightResolution?.cancel()
    inFlightResolution = nil
  }

  private func resolveExecutableURL(shell: ShellClient) async throws -> URL {
    if let executableURL = await locateExecutableURL(
      shell: shell,
      useLoginShell: false
    ) {
      return executableURL
    }
    if let executableURL = await locateExecutableURL(
      shell: shell,
      useLoginShell: true
    ) {
      return executableURL
    }
    throw GithubCLIError.unavailable
  }

  private func locateExecutableURL(
    shell: ShellClient,
    useLoginShell: Bool
  ) async -> URL? {
    let whichURL = URL(fileURLWithPath: "/usr/bin/which")
    do {
      let output: String
      if useLoginShell {
        output = try await shell.runLogin(
          whichURL,
          ["gh"],
          nil,
          log: false
        ).stdout
      } else {
        output = try await shell.run(whichURL, ["gh"], nil).stdout
      }
      let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        return nil
      }
      return URL(fileURLWithPath: trimmed)
    } catch {
      return nil
    }
  }
}
