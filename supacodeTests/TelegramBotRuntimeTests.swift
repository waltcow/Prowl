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
    #expect(routedCommands.value.count == 1)
    guard case .read(let input) = routedCommands.value.first else {
      Issue.record("Expected read command, got \(String(describing: routedCommands.value.first))")
      return
    }
    #expect(input.selector == .pane("pane-123"))
    #expect(input.last == 12)
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
}
