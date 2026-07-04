import Dependencies
import Foundation

struct TelegramBotRuntimeClient: Sendable, DependencyKey {
  var agentEntryChanged: @MainActor @Sendable (ActiveAgentEntry) async -> Void
  var agentEntryRemoved: @MainActor @Sendable (UUID) async -> Void

  static let liveValue = TelegramBotRuntimeClient(
    agentEntryChanged: { _ in },
    agentEntryRemoved: { _ in }
  )

  static let testValue = TelegramBotRuntimeClient(
    agentEntryChanged: { _ in },
    agentEntryRemoved: { _ in }
  )
}

extension DependencyValues {
  var telegramBotRuntimeClient: TelegramBotRuntimeClient {
    get { self[TelegramBotRuntimeClient.self] }
    set { self[TelegramBotRuntimeClient.self] = newValue }
  }
}
