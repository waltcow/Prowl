import ComposableArchitecture
import Foundation
import Testing

@testable import supacode

@MainActor
struct TelegramBotTopicRenameTests {
  @Test func bindPaneRenamesForumTopicUsingAgentMetadata() async throws {
    let paneID = "89CE4CEF-DC2D-4BCE-8526-134C403C3884"
    let bindingStore = TelegramThreadBindingStore(fileURL: nil)
    let renamedTopics = LockIsolated<[String]>([])
    let sentMessages = LockIsolated<[String]>([])
    let processor = TelegramBotUpdateProcessor(
      configuration: Self.configuration,
      bindingStore: bindingStore,
      route: { envelope in
        guard case .agents = envelope.command else {
          return CommandResponse(
            ok: true, command: envelope.command.name, schemaVersion: "prowl.cli.\(envelope.command.name).v1")
        }
        return try! Self.agentsResponse(
          paneID: paneID,
          projectName: "Prowl",
          branchName: "feature/topic-rename",
          agentName: "codex"
        )
      },
      sendMessage: { _, text in
        sentMessages.withValue { $0.append(text) }
      },
      editForumTopic: { target, name in
        renamedTopics.withValue { $0.append("\(target.chatID):\(target.threadID ?? -1):\(name)") }
      }
    )
    let update = Self.update(text: "/bind_pane \(paneID)")

    _ = await processor.process(updates: [update])

    #expect(sentMessages.value == ["Bound this Telegram thread to pane \(paneID)."])
    #expect(renamedTopics.value == ["100:55:Prowl - codex - feature/topic-rename"])
    #expect(
      bindingStore.binding(for: TelegramBotTarget(chatID: 100, threadID: 55))?.displayName
        == "Prowl - codex - feature/topic-rename")
  }

  @Test func bindPaneKeepsBindingWhenForumTopicRenameFails() async throws {
    let paneID = "89CE4CEF-DC2D-4BCE-8526-134C403C3884"
    let bindingStore = TelegramThreadBindingStore(fileURL: nil)
    let sentMessages = LockIsolated<[String]>([])
    let renameAttempts = LockIsolated<[String]>([])
    let processor = TelegramBotUpdateProcessor(
      configuration: Self.configuration,
      bindingStore: bindingStore,
      route: { envelope in
        guard case .agents = envelope.command else {
          return CommandResponse(
            ok: true, command: envelope.command.name, schemaVersion: "prowl.cli.\(envelope.command.name).v1")
        }
        return try! Self.agentsResponse(
          paneID: paneID,
          projectName: "Prowl",
          branchName: "",
          agentName: "codex"
        )
      },
      sendMessage: { _, text in
        sentMessages.withValue { $0.append(text) }
      },
      editForumTopic: { target, name in
        renameAttempts.withValue { $0.append("\(target.chatID):\(target.threadID ?? -1):\(name)") }
        throw TelegramBotClientError.invalidResponse
      }
    )
    let update = Self.update(text: "/bind_pane \(paneID)")

    _ = await processor.process(updates: [update])

    #expect(sentMessages.value == ["Bound this Telegram thread to pane \(paneID)."])
    #expect(renameAttempts.value == ["100:55:Prowl - codex"])
    #expect(bindingStore.binding(for: TelegramBotTarget(chatID: 100, threadID: 55))?.selector == .pane(paneID))
    #expect(bindingStore.binding(for: TelegramBotTarget(chatID: 100, threadID: 55))?.displayName == "Prowl - codex")
  }

  private static let configuration = TelegramBotConfiguration(
    enabled: true,
    token: "secret",
    allowedUserIDs: [42],
    defaultReadLines: 80,
    requireExplicitPaneForWrite: true
  )

  private static func update(text: String) -> TelegramBotUpdate {
    TelegramBotUpdate(
      updateID: 10,
      message: TelegramBotMessage(
        messageID: 1,
        messageThreadID: 55,
        from: TelegramBotUser(id: 42, isBot: false, firstName: "Yes", username: nil),
        chat: TelegramBotChat(id: 100),
        text: text
      )
    )
  }

  private static func agentsResponse(
    paneID: String,
    projectName: String,
    branchName: String,
    agentName: String
  ) throws -> CommandResponse {
    let payload = AgentsCommandPayload(
      count: 1,
      agents: [
        AgentsCommandAgent(
          id: paneID,
          type: "codex",
          name: agentName,
          status: .working,
          rawState: "working",
          lastChangedAt: "2026-07-03T00:00:00Z",
          project: AgentsCommandProject(name: projectName, branch: branchName, path: "/repo/Prowl"),
          worktree: AgentsCommandWorktree(
            id: "/repo/Prowl",
            name: projectName,
            path: "/repo/Prowl",
            rootPath: "/repo",
            kind: "git"
          ),
          tab: AgentsCommandTab(id: UUID().uuidString, title: agentName, selected: true),
          pane: AgentsCommandPane(id: paneID, index: 1, title: agentName, cwd: "/repo/Prowl", focused: true)
        )
      ]
    )
    return try CommandResponse(
      ok: true,
      command: "agents",
      schemaVersion: "prowl.cli.agents.v1",
      data: RawJSON(encoding: payload)
    )
  }
}
