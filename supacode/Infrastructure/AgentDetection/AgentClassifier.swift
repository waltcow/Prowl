import Foundation

func identifyAgent(processName: String) -> DetectedAgent? {
  switch processName.lowercased() {
  case "pi", "omp", "oh-my-pi":
    return .pi
  case "claude", "claude-code":
    return .claude
  case "codex", "omx", "oh-my-codex":
    return .codex
  case "gemini":
    return .gemini
  case "cursor", "cursor-agent":
    return .cursor
  case "cline":
    return .cline
  case "opencode", "open-code":
    return .opencode
  case "copilot", "github-copilot", "ghcs":
    return .copilot
  case "kimi", "kimi code":
    return .kimi
  case "droid":
    return .droid
  case "amp", "amp-local":
    return .amp
  case "qwen":
    return .qwen
  default:
    return nil
  }
}

func identifyAgentInJob(_ job: ForegroundJob) -> (agent: DetectedAgent, name: String)? {
  var best: AgentCandidate?

  for process in job.processes {
    for candidate in agentCandidates(for: process) {
      guard let agent = identifyAgent(candidate: candidate, process: process) else { continue }
      if best == nil || candidate.score > best!.score {
        best = AgentCandidate(score: candidate.score, agent: agent, name: candidate.name)
      }
    }
  }

  return best.map { ($0.agent, $0.name) }
}

private func agentCandidates(for process: ForegroundProcess) -> [(name: String, score: Int)] {
  var candidates: [(String, Int)] = []

  if let argv0 = process.argv0, let name = normalizedProcessName(argv0) {
    candidates.append((name, 80))
  }
  if let name = normalizedProcessName(process.name) {
    candidates.append((name, 70))
  }

  let primaryName = normalizedProcessName(process.argv0 ?? process.name) ?? process.name.lowercased()
  if isWrappedRuntime(primaryName), let cmdline = process.cmdline {
    for token in cmdline.split(whereSeparator: \.isWhitespace) {
      guard let name = normalizedProcessName(String(token)) else { continue }
      candidates.append((name, 40))
    }
  }

  return candidates
}

private func identifyAgent(candidate: (name: String, score: Int), process: ForegroundProcess) -> DetectedAgent? {
  if candidate.name == "agent", isCursorAgentAlias(process) {
    return .cursor
  }
  return identifyAgent(processName: candidate.name)
}

private func isCursorAgentAlias(_ process: ForegroundProcess) -> Bool {
  let haystack = [
    process.argv0,
    process.cmdline,
  ]
  .compactMap(\.self)
  .joined(separator: " ")
  .lowercased()

  return haystack.contains("cursor-agent")
    || haystack.contains("cursor.app")
}

private struct AgentCandidate {
  let score: Int
  let agent: DetectedAgent
  let name: String
}

private func normalizedProcessName(_ raw: String) -> String? {
  guard let basename = ProcessDetection.basename(raw) else { return nil }
  let lower = basename.lowercased()
  if lower.hasSuffix(".js") {
    return String(lower.dropLast(3))
  }
  return lower
}

private func isWrappedRuntime(_ name: String) -> Bool {
  [
    "node", "bun", "python", "python3", "ruby", "deno",
    "sh", "bash", "zsh", "fish", "tmux", "npx", "bunx",
  ].contains(name)
}
