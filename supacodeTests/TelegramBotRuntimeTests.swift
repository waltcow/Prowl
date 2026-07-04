import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import supacode

@MainActor
struct TelegramBotRuntimeTests {
  @Test func processorIgnoresUnauthorizedUsersAndAdvancesOffset() async {
    let routedCommands = LockIsolated<[String]>([])
    let sentMessages = LockIsolated<[String]>([])
    let processor = TelegramBotUpdateProcessor(
      configuration: TelegramBotConfiguration(
        enabled: true,
        token: "secret",
        allowedUserIDs: [42],
        defaultReadLines: 80,
        requireExplicitPaneForWrite: true
      ),
      route: { envelope in
        let commandName = envelope.command.name
        routedCommands.withValue { $0.append(commandName) }
        return CommandResponse(ok: true, command: commandName, schemaVersion: "prowl.cli.\(commandName).v1")
      },
      sendMessage: { _, text in
        sentMessages.withValue { $0.append(text) }
      }
    )
    let update = TelegramBotUpdate(
      updateID: 10,
      message: TelegramBotMessage(
        messageID: 1,
        from: TelegramBotUser(id: 7, isBot: false, firstName: "No", username: nil),
        chat: TelegramBotChat(id: 100),
        text: "/list"
      )
    )

    let nextOffset = await processor.process(updates: [update])

    #expect(nextOffset == 11)
    #expect(routedCommands.value.isEmpty)
    #expect(sentMessages.value.isEmpty)
  }

  @Test func processorRoutesAuthorizedCommandAndSendsFormattedResponse() async throws {
    let routedCommands = LockIsolated<[String]>([])
    let sentMessages = LockIsolated<[String]>([])
    let payload = ListCommandPayload(count: 0, items: [])
    let response = try CommandResponse(
      ok: true,
      command: "list",
      schemaVersion: "prowl.cli.list.v1",
      data: RawJSON(encoding: payload)
    )
    let processor = TelegramBotUpdateProcessor(
      configuration: TelegramBotConfiguration(
        enabled: true,
        token: "secret",
        allowedUserIDs: [42],
        defaultReadLines: 80,
        requireExplicitPaneForWrite: true
      ),
      route: { envelope in
        let commandName = envelope.command.name
        routedCommands.withValue { $0.append(commandName) }
        return response
      },
      sendMessage: { target, text in
        sentMessages.withValue { $0.append("\(target.chatID):\(text)") }
      }
    )
    let update = TelegramBotUpdate(
      updateID: 20,
      message: TelegramBotMessage(
        messageID: 1,
        from: TelegramBotUser(id: 42, isBot: false, firstName: "Yes", username: nil),
        chat: TelegramBotChat(id: 100),
        text: "/list"
      )
    )

    let nextOffset = await processor.process(updates: [update])

    #expect(nextOffset == 21)
    #expect(routedCommands.value == ["list"])
    #expect(sentMessages.value == ["100:No panes found."])
  }

  @Test func processorRepliesToTheSourceTelegramThread() async throws {
    let sentTargets = LockIsolated<[TelegramBotTarget]>([])
    let processor = TelegramBotUpdateProcessor(
      configuration: TelegramBotConfiguration(
        enabled: true,
        token: "secret",
        allowedUserIDs: [42],
        defaultReadLines: 80,
        requireExplicitPaneForWrite: true
      ),
      route: { envelope in
        CommandResponse(
          ok: true,
          command: envelope.command.name,
          schemaVersion: "prowl.cli.\(envelope.command.name).v1"
        )
      },
      sendMessage: { target, _ in
        sentTargets.withValue { $0.append(target) }
      }
    )
    let update = TelegramBotUpdate(
      updateID: 21,
      message: TelegramBotMessage(
        messageID: 1,
        messageThreadID: 55,
        from: TelegramBotUser(id: 42, isBot: false, firstName: "Yes", username: nil),
        chat: TelegramBotChat(id: 100),
        text: "/agents"
      )
    )

    _ = await processor.process(updates: [update])

    #expect(sentTargets.value == [TelegramBotTarget(chatID: 100, threadID: 55)])
  }

  @Test func processorBindsThreadAndRoutesReadThroughBoundSelector() async throws {
    let routedCommands = LockIsolated<[Command]>([])
    let sentMessages = LockIsolated<[String]>([])
    let bindingStore = TelegramThreadBindingStore(fileURL: nil)
    let processor = TelegramBotUpdateProcessor(
      configuration: TelegramBotConfiguration(
        enabled: true,
        token: "secret",
        allowedUserIDs: [42],
        defaultReadLines: 80,
        requireExplicitPaneForWrite: true
      ),
      bindingStore: bindingStore,
      route: { envelope in
        let command = envelope.command
        routedCommands.withValue { $0.append(command) }
        return CommandResponse(ok: true, command: command.name, schemaVersion: "prowl.cli.\(command.name).v1")
      },
      sendMessage: { _, text in
        sentMessages.withValue { $0.append(text) }
      }
    )
    let bindUpdate = TelegramBotUpdate(
      updateID: 30,
      message: TelegramBotMessage(
        messageID: 1,
        messageThreadID: 55,
        from: TelegramBotUser(id: 42, isBot: false, firstName: "Yes", username: nil),
        chat: TelegramBotChat(id: 100),
        text: "/bind_pane pane-123"
      )
    )
    let readUpdate = TelegramBotUpdate(
      updateID: 31,
      message: TelegramBotMessage(
        messageID: 2,
        messageThreadID: 55,
        from: TelegramBotUser(id: 42, isBot: false, firstName: "Yes", username: nil),
        chat: TelegramBotChat(id: 100),
        text: "/read 12"
      )
    )

    _ = await processor.process(updates: [bindUpdate, readUpdate])

    #expect(sentMessages.value.first == "Bound this Telegram thread to pane pane-123.")
    let readCommands = routedCommands.value.compactMap { command -> ReadInput? in
      guard case .read(let input) = command else { return nil }
      return input
    }
    #expect(readCommands.count == 1)
    guard let input = readCommands.first else {
      Issue.record("Expected read command, got \(routedCommands.value)")
      return
    }
    #expect(input.selector == .pane("pane-123"))
    #expect(input.last == 12)
  }

  @Test func processorRoutesPlainTextThroughBoundPane() async throws {
    let routedCommands = LockIsolated<[Command]>([])
    let sentMessages = LockIsolated<[String]>([])
    let reactionCalls = LockIsolated<[String]>([])
    let bindingStore = TelegramThreadBindingStore(fileURL: nil)
    let processor = TelegramBotUpdateProcessor(
      configuration: TelegramBotConfiguration(
        enabled: true,
        token: "secret",
        allowedUserIDs: [42],
        defaultReadLines: 80,
        requireExplicitPaneForWrite: true
      ),
      bindingStore: bindingStore,
      route: { envelope in
        let command = envelope.command
        routedCommands.withValue { $0.append(command) }
        return CommandResponse(ok: true, command: command.name, schemaVersion: "prowl.cli.\(command.name).v1")
      },
      sendMessage: { _, text in
        sentMessages.withValue { $0.append(text) }
      },
      setMessageReaction: { target, messageID, emoji in
        reactionCalls.withValue {
          $0.append("\(target.chatID):\(target.threadID ?? -1):\(messageID):\(emoji)")
        }
      }
    )
    let bindUpdate = TelegramBotUpdate(
      updateID: 40,
      message: TelegramBotMessage(
        messageID: 1,
        messageThreadID: 55,
        from: TelegramBotUser(id: 42, isBot: false, firstName: "Yes", username: nil),
        chat: TelegramBotChat(id: 100),
        text: "/bind_pane pane-123"
      )
    )
    let plainTextUpdate = TelegramBotUpdate(
      updateID: 41,
      message: TelegramBotMessage(
        messageID: 2,
        messageThreadID: 55,
        from: TelegramBotUser(id: 42, isBot: false, firstName: "Yes", username: nil),
        chat: TelegramBotChat(id: 100),
        text: "echo hello"
      )
    )

    _ = await processor.process(updates: [bindUpdate, plainTextUpdate])

    #expect(sentMessages.value == ["Bound this Telegram thread to pane pane-123."])
    #expect(reactionCalls.value == ["100:55:2:👀"])
    let sendCommands = routedCommands.value.compactMap { command -> SendInput? in
      guard case .send(let input) = command else { return nil }
      return input
    }
    #expect(sendCommands.count == 1)
    guard let input = sendCommands.first else {
      Issue.record("Expected send command, got \(routedCommands.value)")
      return
    }
    #expect(input.selector == .pane("pane-123"))
    #expect(input.text == "echo hello")
    #expect(input.trailingEnter == true)
  }

  @Test func processorFallsBackToMessageWhenPlainTextReactionFails() async throws {
    let routedCommands = LockIsolated<[Command]>([])
    let sentMessages = LockIsolated<[String]>([])
    let reactionCalls = LockIsolated<[String]>([])
    let bindingStore = TelegramThreadBindingStore(fileURL: nil)
    let processor = TelegramBotUpdateProcessor(
      configuration: TelegramBotConfiguration(
        enabled: true,
        token: "secret",
        allowedUserIDs: [42],
        defaultReadLines: 80,
        requireExplicitPaneForWrite: true
      ),
      bindingStore: bindingStore,
      route: { envelope in
        let command = envelope.command
        routedCommands.withValue { $0.append(command) }
        return CommandResponse(ok: true, command: command.name, schemaVersion: "prowl.cli.\(command.name).v1")
      },
      sendMessage: { _, text in
        sentMessages.withValue { $0.append(text) }
      },
      setMessageReaction: { target, messageID, emoji in
        reactionCalls.withValue {
          $0.append("\(target.chatID):\(target.threadID ?? -1):\(messageID):\(emoji)")
        }
        throw TelegramBotClientError.invalidResponse
      }
    )
    let bindUpdate = TelegramBotUpdate(
      updateID: 50,
      message: TelegramBotMessage(
        messageID: 1,
        messageThreadID: 55,
        from: TelegramBotUser(id: 42, isBot: false, firstName: "Yes", username: nil),
        chat: TelegramBotChat(id: 100),
        text: "/bind_pane pane-123"
      )
    )
    let plainTextUpdate = TelegramBotUpdate(
      updateID: 51,
      message: TelegramBotMessage(
        messageID: 2,
        messageThreadID: 55,
        from: TelegramBotUser(id: 42, isBot: false, firstName: "Yes", username: nil),
        chat: TelegramBotChat(id: 100),
        text: "echo hello"
      )
    )

    _ = await processor.process(updates: [bindUpdate, plainTextUpdate])

    #expect(sentMessages.value == ["Bound this Telegram thread to pane pane-123.", "👀"])
    #expect(reactionCalls.value == ["100:55:2:👀"])
    let sendCommands = routedCommands.value.compactMap { command -> SendInput? in
      guard case .send(let input) = command else { return nil }
      return input
    }
    #expect(sendCommands.count == 1)
    guard let input = sendCommands.first else {
      Issue.record("Expected send command, got \(routedCommands.value)")
      return
    }
    #expect(input.selector == .pane("pane-123"))
    #expect(input.text == "echo hello")
    #expect(input.trailingEnter == true)
  }

  @Test func threadBindingStorePersistsBindings() throws {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory.appending(path: "telegram-bindings-\(UUID().uuidString)")
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: directory) }

    let fileURL = directory.appending(path: "bindings.json")
    let target = TelegramBotTarget(chatID: 100, threadID: 55)
    let firstStore = TelegramThreadBindingStore(fileURL: fileURL)

    firstStore.bind(target: target, selector: .pane("pane-123"), displayName: "pane pane-123")
    let secondStore = TelegramThreadBindingStore(fileURL: fileURL)

    #expect(secondStore.binding(for: target)?.selector == .pane("pane-123"))
    #expect(secondStore.binding(for: target)?.displayName == "pane pane-123")
  }

  @Test func runtimePollOnceUsesGetUpdatesOffsetAndReturnsNextOffset() async {
    let requestedOffsets = LockIsolated<[Int?]>([])
    let sentMessages = LockIsolated<[String]>([])
    let client = TelegramBotClient(
      getMe: { _ in TelegramBotUser(id: 1, isBot: true, firstName: "Prowl", username: "prowl_bot") },
      getUpdates: { _, offset, timeout in
        requestedOffsets.withValue { $0.append(offset) }
        #expect(timeout == 30)
        return [
          TelegramBotUpdate(
            updateID: 123,
            message: TelegramBotMessage(
              messageID: 1,
              from: TelegramBotUser(id: 42, isBot: false, firstName: "Yes", username: nil),
              chat: TelegramBotChat(id: 100),
              text: "/agents"
            )
          )
        ]
      },
      sendMessage: { _, target, text in
        sentMessages.withValue { $0.append("\(target.chatID):\(text)") }
      },
      sendReplyMessage: { _, _, _, _ in
        throw TelegramBotClientError.invalidResponse
      },
      editForumTopic: { _, _, _ in },
      setMessageReaction: { _, _, _, _ in
        throw TelegramBotClientError.invalidResponse
      },
      setMyCommands: { _, _ in
        throw TelegramBotClientError.invalidResponse
      }
    )
    let runtime = TelegramBotRuntime(
      client: client,
      route: { envelope in
        let commandName = envelope.command.name
        return CommandResponse(ok: true, command: commandName, schemaVersion: "prowl.cli.\(commandName).v1")
      },
      sleep: { _ in }
    )

    let nextOffset = await runtime.pollOnce(
      configuration: TelegramBotConfiguration(
        enabled: true,
        token: "secret",
        allowedUserIDs: [42],
        defaultReadLines: 80,
        requireExplicitPaneForWrite: true
      ),
      offset: 120
    )

    #expect(nextOffset == 124)
    #expect(requestedOffsets.value.count == 1)
    #expect(requestedOffsets.value[0] == 120)
    #expect(sentMessages.value.count == 1)
  }

  @Test func runtimeRepliesToBoundThreadWhenBoundAgentFinishes() async {
    let paneID = UUID(uuidString: "89CE4CEF-DC2D-4BCE-8526-134C403C3884")!
    let sentMessages = LockIsolated<[String]>([])
    let sentReplies = LockIsolated<[String]>([])
    let reactionCalls = LockIsolated<[String]>([])
    let captures = LockIsolated<[TelegramPaneCapture]>([
      TelegramPaneCapture(viewportText: "hi", screenText: "hi"),
      TelegramPaneCapture(viewportText: "hi\nAgent final answer", screenText: "hi\nAgent final answer"),
    ])
    let client = TelegramBotClient(
      getMe: { _ in TelegramBotUser(id: 1, isBot: true, firstName: "Prowl", username: "prowl_bot") },
      getUpdates: { _, _, _ in
        [
          TelegramBotUpdate(
            updateID: 200,
            message: TelegramBotMessage(
              messageID: 10,
              messageThreadID: 55,
              from: TelegramBotUser(id: 42, isBot: false, firstName: "Yes", username: nil),
              chat: TelegramBotChat(id: 100),
              text: "/bind_pane \(paneID.uuidString)"
            )
          ),
          TelegramBotUpdate(
            updateID: 201,
            message: TelegramBotMessage(
              messageID: 11,
              messageThreadID: 55,
              from: TelegramBotUser(id: 42, isBot: false, firstName: "Yes", username: nil),
              chat: TelegramBotChat(id: 100),
              text: "hi"
            )
          ),
        ]
      },
      sendMessage: { _, target, text in
        sentMessages.withValue { $0.append("\(target.chatID):\(target.threadID ?? -1):\(text)") }
      },
      sendReplyMessage: { token, target, text, replyToMessageID in
        sentReplies.withValue {
          $0.append("\(token):\(target.chatID):\(target.threadID ?? -1):\(replyToMessageID):\(text)")
        }
      },
      editForumTopic: { _, _, _ in },
      setMessageReaction: { _, target, messageID, emoji in
        reactionCalls.withValue {
          $0.append("\(target.chatID):\(target.threadID ?? -1):\(messageID):\(emoji)")
        }
      },
      setMyCommands: { _, _ in
        throw TelegramBotClientError.invalidResponse
      }
    )
    let runtime = TelegramBotRuntime(
      client: client,
      route: { envelope in
        guard case .send = envelope.command else {
          return CommandResponse(
            ok: true,
            command: envelope.command.name,
            schemaVersion: "prowl.cli.\(envelope.command.name).v1"
          )
        }
        return Self.makeSendResponse(paneID: paneID)
      },
      bindingStore: TelegramThreadBindingStore(fileURL: nil),
      sleep: { _ in },
      capturePane: { worktreeID, capturedPaneID in
        #expect(worktreeID == "/repo/worktree")
        #expect(capturedPaneID == paneID)
        return captures.withValue { $0.removeFirst() }
      }
    )

    let nextOffset = await runtime.pollOnce(
      configuration: TelegramBotConfiguration(
        enabled: true,
        token: "secret",
        allowedUserIDs: [42],
        defaultReadLines: 80,
        requireExplicitPaneForWrite: true
      ),
      offset: nil
    )

    #expect(nextOffset == 202)
    #expect(sentMessages.value == ["100:55:Bound this Telegram thread to pane \(paneID.uuidString)."])
    #expect(reactionCalls.value == ["100:55:11:👀"])
    #expect(sentReplies.value.isEmpty)

    await runtime.agentEntryChanged(Self.activeAgentEntry(surfaceID: paneID, displayState: .working))
    await runtime.agentEntryChanged(Self.activeAgentEntry(surfaceID: paneID, displayState: .done))

    #expect(sentReplies.value == ["secret:100:55:11:Agent final answer"])
  }

  @Test func runtimeDoesNotReplyBeforeObservedBusyState() async {
    let paneID = UUID(uuidString: "89CE4CEF-DC2D-4BCE-8526-134C403C3884")!
    let sentReplies = LockIsolated<[String]>([])
    let captures = LockIsolated<[TelegramPaneCapture]>([
      TelegramPaneCapture(viewportText: "hi", screenText: "hi"),
      TelegramPaneCapture(viewportText: "hi\nAgent final answer", screenText: "hi\nAgent final answer"),
    ])
    let client = TelegramBotClient(
      getMe: { _ in TelegramBotUser(id: 1, isBot: true, firstName: "Prowl", username: "prowl_bot") },
      getUpdates: { _, _, _ in
        [
          TelegramBotUpdate(
            updateID: 300,
            message: TelegramBotMessage(
              messageID: 10,
              messageThreadID: 55,
              from: TelegramBotUser(id: 42, isBot: false, firstName: "Yes", username: nil),
              chat: TelegramBotChat(id: 100),
              text: "/bind_pane \(paneID.uuidString)"
            )
          ),
          TelegramBotUpdate(
            updateID: 301,
            message: TelegramBotMessage(
              messageID: 11,
              messageThreadID: 55,
              from: TelegramBotUser(id: 42, isBot: false, firstName: "Yes", username: nil),
              chat: TelegramBotChat(id: 100),
              text: "hi"
            )
          ),
        ]
      },
      sendMessage: { _, _, _ in },
      sendReplyMessage: { token, target, text, replyToMessageID in
        sentReplies.withValue {
          $0.append("\(token):\(target.chatID):\(target.threadID ?? -1):\(replyToMessageID):\(text)")
        }
      },
      editForumTopic: { _, _, _ in },
      setMessageReaction: { _, _, _, _ in },
      setMyCommands: { _, _ in
        throw TelegramBotClientError.invalidResponse
      }
    )
    let runtime = TelegramBotRuntime(
      client: client,
      route: { envelope in
        guard case .send = envelope.command else {
          return CommandResponse(
            ok: true,
            command: envelope.command.name,
            schemaVersion: "prowl.cli.\(envelope.command.name).v1"
          )
        }
        return Self.makeSendResponse(paneID: paneID)
      },
      bindingStore: TelegramThreadBindingStore(fileURL: nil),
      sleep: { _ in },
      capturePane: { _, _ in captures.withValue { $0.removeFirst() } }
    )

    _ = await runtime.pollOnce(
      configuration: TelegramBotConfiguration(
        enabled: true,
        token: "secret",
        allowedUserIDs: [42],
        defaultReadLines: 80,
        requireExplicitPaneForWrite: true
      ),
      offset: nil
    )
    await runtime.agentEntryChanged(Self.activeAgentEntry(surfaceID: paneID, displayState: .done))

    #expect(sentReplies.value.isEmpty)
    #expect(captures.value.count == 1)
  }

  private static func makeSendResponse(paneID: UUID) -> CommandResponse {
    let payload = SendCommandPayload(
      target: SendTarget(
        worktree: SendTargetWorktree(
          id: "/repo/worktree",
          name: "worktree",
          path: "/repo/worktree",
          rootPath: "/repo",
          kind: "git"
        ),
        tab: SendTargetTab(id: UUID().uuidString, title: "codex", selected: true),
        pane: SendTargetPane(id: paneID.uuidString, title: "codex", cwd: "/repo/worktree", focused: true)
      ),
      input: SendInputInfo(source: "telegram", characters: 2, bytes: 2, trailingEnterSent: true),
      createdTab: false,
      wait: nil
    )
    return try! CommandResponse(
      ok: true,
      command: "send",
      schemaVersion: "prowl.cli.send.v1",
      data: RawJSON(encoding: payload)
    )
  }

  private static func activeAgentEntry(surfaceID: UUID, displayState: AgentDisplayState) -> ActiveAgentEntry {
    ActiveAgentEntry(
      id: surfaceID,
      worktreeID: "/repo/worktree",
      worktreeName: "worktree",
      workingDirectory: nil,
      tabID: TerminalTabID(rawValue: UUID()),
      tabTitle: "codex",
      surfaceID: surfaceID,
      paneIndex: 0,
      iconLookupToken: DetectedAgent.codex.iconLookupToken,
      agent: .codex,
      rawState: displayState == .working ? .working : .idle,
      displayState: displayState,
      lastChangedAt: Date(timeIntervalSince1970: 10)
    )
  }
}
