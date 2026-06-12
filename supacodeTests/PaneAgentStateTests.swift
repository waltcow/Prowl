import Foundation
import Testing

@testable import supacode

struct PaneAgentStateTests {
  @Test func displayStateDerivesDoneFromUnseenIdle() {
    var state = PaneAgentState(
      detectedAgent: .codex,
      fallbackState: .idle,
      state: .idle,
      seen: false,
      lastChangedAt: Date(timeIntervalSince1970: 0)
    )

    #expect(state.displayState == .done)
    state.seen = true
    #expect(state.displayState == .idle)
  }

  @Test(arguments: [DetectedAgent.claude, .codex, .gemini])
  func workingIsStickyForShortIdleGap(agent: DetectedAgent) {
    let now = Date(timeIntervalSince1970: 100)
    var lastWorking: Date?

    let working = stabilizeAgentState(
      agent: agent,
      previous: .idle,
      raw: .working,
      now: now,
      lastWorkingAt: &lastWorking
    )
    #expect(working == .working)

    let stillWorking = stabilizeAgentState(
      agent: agent,
      previous: .working,
      raw: .idle,
      now: now.addingTimeInterval(2.9),
      lastWorkingAt: &lastWorking
    )
    #expect(stillWorking == .working)
  }

  @Test(arguments: [DetectedAgent.claude, .codex])
  func transitionsToIdleAfterStickyWindow(agent: DetectedAgent) {
    let now = Date(timeIntervalSince1970: 100)
    var lastWorking: Date? = now

    let idle = stabilizeAgentState(
      agent: agent,
      previous: .working,
      raw: .idle,
      now: now.addingTimeInterval(3.001),
      lastWorkingAt: &lastWorking
    )

    #expect(idle == .idle)
  }

  @Test func blockedBypassesStickyWindow() {
    let now = Date(timeIntervalSince1970: 100)
    var lastWorking: Date? = now

    let blocked = stabilizeAgentState(
      agent: .claude,
      previous: .working,
      raw: .blocked,
      now: now.addingTimeInterval(0.3),
      lastWorkingAt: &lastWorking
    )

    #expect(blocked == .blocked)
  }

  @Test func presenceRequiresSixMissesBeforeRelease() {
    var presence = AgentDetectionPresence(currentAgent: .codex)

    for _ in 0..<5 {
      #expect(presence.update(detectedAgent: nil) == .codex)
    }
    #expect(presence.update(detectedAgent: nil) == nil)
    #expect(presence.currentAgent == nil)
  }
}
