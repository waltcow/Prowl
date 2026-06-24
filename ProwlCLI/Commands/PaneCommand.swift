// ProwlCLI/Commands/PaneCommand.swift

import ArgumentParser
import ProwlCLIShared

struct PaneCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pane",
    abstract: "Manage terminal panes.",
    subcommands: [
      PaneCloseCommand.self,
    ]
  )
}

struct PaneCloseCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "close",
    abstract: "Close a terminal pane."
  )

  @OptionGroup var selector: SelectorOptions
  @OptionGroup var options: GlobalOptions

  @Flag(name: .long, help: "Close without prompting for protected panes.")
  var force = false

  mutating func run() throws {
    try CLIExecution.run(command: "pane", output: options.outputMode, colorEnabled: options.colorEnabled) {
      let resolvedSelector = try selector.resolve()
      guard !resolvedSelector.isNone else {
        throw ExitError(
          code: CLIErrorCode.invalidArgument,
          message: "pane close requires an explicit target selector."
        )
      }
      let envelope = CommandEnvelope(
        output: options.outputMode,
        command: .pane(PaneInput(action: .close, selector: resolvedSelector, force: force))
      )
      try CLIRunner.execute(envelope)
    }
  }
}
