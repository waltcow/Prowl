import Foundation

enum TerminalOutputDiff {
  static func diff(pre: ReadCaptureInput, post: ReadCaptureInput, commandText: String) -> CapturedOutput {
    let preText = pre.screenText ?? pre.viewportText
    let postText = post.screenText ?? post.viewportText

    let preLines = trimTrailingBlankLines(splitLines(preText))
    let postLines = trimTrailingBlankLines(splitLines(postText))

    if postLines.count < preLines.count {
      let count = postLines.isEmpty ? 0 : postLines.count
      return CapturedOutput(text: postText, lineCount: count, source: .screenDiff, truncated: true)
    }

    let commonPrefixLength = zip(preLines, postLines).prefix(while: { $0 == $1 }).count
    var newLines = Array(postLines.dropFirst(commonPrefixLength))

    let trimmedCommand = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
    if let first = newLines.first {
      let firstStr = String(first).trimmingCharacters(in: .whitespacesAndNewlines)
      if firstStr == trimmedCommand || firstStr.hasSuffix(trimmedCommand) {
        newLines = Array(newLines.dropFirst())
      }
    }

    if let lastPre = preLines.last, let lastNew = newLines.last, lastNew == lastPre {
      newLines = Array(newLines.dropLast())
    }

    while let last = newLines.last, String(last).trimmingCharacters(in: .whitespaces).isEmpty {
      newLines = Array(newLines.dropLast())
    }

    if newLines.isEmpty {
      return CapturedOutput(text: "", lineCount: 0, source: .screenDiff, truncated: false)
    }

    let resultText = newLines.map(String.init).joined(separator: "\n")
    return CapturedOutput(text: resultText, lineCount: newLines.count, source: .screenDiff, truncated: false)
  }

  private static func splitLines(_ text: String) -> [Substring] {
    guard !text.isEmpty else { return [] }
    return text.split(separator: "\n", omittingEmptySubsequences: false)
  }

  private static func trimTrailingBlankLines(_ lines: [Substring]) -> [Substring] {
    var result = lines
    while let last = result.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
      result.removeLast()
    }
    return result
  }
}
