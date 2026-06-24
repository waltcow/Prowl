import Foundation

struct TerminalCloseProtectionCandidate: Equatable {
  let hasAgent: Bool
  let agentDisplayState: AgentDisplayState?
  let commandRunningDuration: TimeInterval?
}

enum TerminalCloseProtectionReason: Equatable, Hashable {
  case agentActive
  case longRunningCommand
}

struct TerminalCloseConfirmationDecision: Equatable {
  let protectedPaneCount: Int
  let reasons: Set<TerminalCloseProtectionReason>

  var requiresConfirmation: Bool {
    protectedPaneCount > 0
  }
}

enum TerminalCloseConfirmationPolicy {
  static let longRunningCommandThreshold: TimeInterval = 10

  static func decision(
    for candidates: [TerminalCloseProtectionCandidate],
    threshold: TimeInterval = Self.longRunningCommandThreshold
  ) -> TerminalCloseConfirmationDecision {
    var protectedPaneCount = 0
    var reasons: Set<TerminalCloseProtectionReason> = []

    for candidate in candidates {
      guard let reason = protectionReason(for: candidate, threshold: threshold) else { continue }
      protectedPaneCount += 1
      reasons.insert(reason)
    }

    return TerminalCloseConfirmationDecision(
      protectedPaneCount: protectedPaneCount,
      reasons: reasons
    )
  }

  private static func protectionReason(
    for candidate: TerminalCloseProtectionCandidate,
    threshold: TimeInterval
  ) -> TerminalCloseProtectionReason? {
    if candidate.hasAgent {
      switch candidate.agentDisplayState {
      case .working, .blocked, .done:
        return .agentActive
      case .idle, .none:
        return nil
      }
    }

    guard let duration = candidate.commandRunningDuration, duration >= threshold else {
      return nil
    }
    return .longRunningCommand
  }
}
