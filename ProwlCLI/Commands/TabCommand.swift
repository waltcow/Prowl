// ProwlCLI/Commands/TabCommand.swift

import ArgumentParser
import Foundation
import ProwlCLIShared

struct TabCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tab",
    abstract: "Create or close terminal tabs.",
    subcommands: [
      TabCreateCommand.self,
      TabCloseCommand.self,
    ]
  )
}

struct TabCreateCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "create",
    abstract: "Create a new terminal tab."
  )

  @OptionGroup var selector: SelectorOptions
  @OptionGroup var options: GlobalOptions

  @Option(name: .long, help: "Working directory for the new tab.")
  var path: String?

  mutating func run() throws {
    try CLIExecution.run(command: "tab", output: options.outputMode, colorEnabled: options.colorEnabled) {
      let envelope = CommandEnvelope(
        output: options.outputMode,
        command: .tab(TabInput(action: .create, selector: try selector.resolve(), path: normalizedPath()))
      )
      try CLIRunner.execute(envelope)
    }
  }

  private func normalizedPath() -> String? {
    guard let path else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
      .standardizedFileURL
      .path(percentEncoded: false)
      .trimmingTrailingSlash()
  }
}

struct TabCloseCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "close",
    abstract: "Close a terminal tab."
  )

  @OptionGroup var selector: SelectorOptions
  @OptionGroup var options: GlobalOptions

  @Flag(name: .long, help: "Close without prompting for protected panes.")
  var force = false

  mutating func run() throws {
    try CLIExecution.run(command: "tab", output: options.outputMode, colorEnabled: options.colorEnabled) {
      let resolvedSelector = try selector.resolve()
      guard !resolvedSelector.isNone else {
        throw ExitError(
          code: CLIErrorCode.invalidArgument,
          message: "tab close requires an explicit target selector."
        )
      }
      let envelope = CommandEnvelope(
        output: options.outputMode,
        command: .tab(TabInput(action: .close, selector: resolvedSelector, force: force))
      )
      try CLIRunner.execute(envelope)
    }
  }
}

extension String {
  fileprivate func trimmingTrailingSlash() -> String {
    var value = self
    while value.count > 1, value.hasSuffix("/") {
      value.removeLast()
    }
    return value
  }
}
