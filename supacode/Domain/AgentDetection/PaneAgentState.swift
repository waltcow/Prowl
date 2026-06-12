import Foundation

struct PaneAgentState: Equatable, Sendable {
  var detectedAgent: DetectedAgent?
  var fallbackState: AgentRawState
  var state: AgentRawState
  var seen: Bool
  var lastChangedAt: Date

  init(
    detectedAgent: DetectedAgent? = nil,
    fallbackState: AgentRawState = .unknown,
    state: AgentRawState = .unknown,
    seen: Bool = true,
    lastChangedAt: Date = Date()
  ) {
    self.detectedAgent = detectedAgent
    self.fallbackState = fallbackState
    self.state = state
    self.seen = seen
    self.lastChangedAt = lastChangedAt
  }

  var displayState: AgentDisplayState {
    switch state {
    case .working:
      return .working
    case .blocked:
      return .blocked
    case .idle:
      return seen ? .idle : .done
    case .unknown:
      return .idle
    }
  }
}

struct AgentDetectionPresence: Equatable, Sendable {
  static let releaseMissThreshold = 6

  var currentAgent: DetectedAgent?
  var consecutiveMisses: UInt8

  init(currentAgent: DetectedAgent? = nil, consecutiveMisses: UInt8 = 0) {
    self.currentAgent = currentAgent
    self.consecutiveMisses = consecutiveMisses
  }

  mutating func update(detectedAgent: DetectedAgent?) -> DetectedAgent? {
    if let detectedAgent {
      currentAgent = detectedAgent
      consecutiveMisses = 0
      return detectedAgent
    }

    guard currentAgent != nil else {
      consecutiveMisses = 0
      return nil
    }

    consecutiveMisses = min(consecutiveMisses + 1, UInt8(Self.releaseMissThreshold))
    if consecutiveMisses >= Self.releaseMissThreshold {
      currentAgent = nil
      consecutiveMisses = 0
    }
    return currentAgent
  }
}

// Agents briefly clear their working indicators between steps (output gaps,
// tool-call boundaries), so a raw working → idle flip is only trusted after
// the screen has read idle for this long. Keeps Working from flapping to
// Done and back during those pauses, at the cost of reporting a genuine
// finish up to this much later.
private let workingStateHold: TimeInterval = 3.0

func stabilizeAgentState(
  agent: DetectedAgent?,
  previous: AgentRawState,
  raw: AgentRawState,
  now: Date,
  lastWorkingAt: inout Date?
) -> AgentRawState {
  guard agent != nil else {
    lastWorkingAt = nil
    return raw
  }

  switch raw {
  case .working:
    lastWorkingAt = now
    return .working
  case .blocked:
    return .blocked
  case .idle where previous == .working:
    guard let lastWorkingAt else {
      return .idle
    }
    return now.timeIntervalSince(lastWorkingAt) < workingStateHold ? .working : .idle
  case .idle, .unknown:
    return raw
  }
}
