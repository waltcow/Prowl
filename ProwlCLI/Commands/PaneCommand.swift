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

  mutating func run() throws {
    try CLIExecution.run(command: "pane", output: options.outputMode, colorEnabled: options.colorEnabled) {
      let envelope = CommandEnvelope(
        output: options.outputMode,
        command: .pane(PaneInput(action: .close, selector: try selector.resolve()))
      )
      try CLIRunner.execute(envelope)
    }
  }
}
