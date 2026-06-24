import Foundation

enum AgentRawState: String, Equatable, Sendable {
  case working
  case blocked
  case idle
  case unknown
}

enum AgentDisplayState: String, Equatable, Sendable {
  case working
  case blocked
  case done
  case idle
}
