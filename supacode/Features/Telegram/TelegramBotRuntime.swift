import Foundation

private nonisolated let telegramBotLogger = SupaLogger("TelegramBot")

struct TelegramBotConfiguration: Equatable, Sendable {
  var enabled: Bool
  var token: String?
  var allowedUserIDs: [Int64]
  var defaultReadLines: Int
  var requireExplicitPaneForWrite: Bool

  var activeToken: String? {
    let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  var canRun: Bool {
    enabled && activeToken != nil && !allowedUserIDs.isEmpty
  }

  var normalized: TelegramBotConfiguration {
    TelegramBotConfiguration(
      enabled: enabled,
      token: activeToken,
      allowedUserIDs: allowedUserIDs,
      defaultReadLines: max(1, min(defaultReadLines, 500)),
      requireExplicitPaneForWrite: requireExplicitPaneForWrite
    )
  }
}

struct TelegramThreadBinding: Codable, Equatable, Sendable {
  let target: TelegramBotTarget
  let selector: TargetSelector
  let displayName: String
  let updatedAt: Date
}

@MainActor
final class TelegramThreadBindingStore {
  private let fileURL: URL?
  private var bindings: [TelegramBotTarget: TelegramThreadBinding] = [:]

  init(
    fileURL: URL? = SupacodePaths.baseDirectory.appending(
      path: "telegram-thread-bindings.json",
      directoryHint: .notDirectory
    )
  ) {
    self.fileURL = fileURL
    load()
  }

  func binding(for target: TelegramBotTarget) -> TelegramThreadBinding? {
    bindings[target]
  }

  @discardableResult
  func bind(target: TelegramBotTarget, selector: TargetSelector, displayName: String) -> TelegramThreadBinding {
    let binding = TelegramThreadBinding(target: target, selector: selector, displayName: displayName, updatedAt: Date())
    bindings[target] = binding
    persist()
    return binding
  }

  @discardableResult
  func unbind(target: TelegramBotTarget) -> Bool {
    guard bindings.removeValue(forKey: target) != nil else { return false }
    persist()
    return true
  }

  func allBindings() -> [TelegramThreadBinding] {
    sortedBindings()
  }

  private func load() {
    guard let fileURL else { return }
    let path = fileURL.path(percentEncoded: false)
    guard FileManager.default.fileExists(atPath: path) else { return }

    do {
      let data = try Data(contentsOf: fileURL)
      let decoded = try JSONDecoder().decode([TelegramThreadBinding].self, from: data)
      bindings = Dictionary(uniqueKeysWithValues: decoded.map { ($0.target, $0) })
    } catch {
      telegramBotLogger.warning("Failed to load Telegram thread bindings: \(String(describing: error))")
    }
  }

  private func persist() {
    guard let fileURL else { return }

    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(sortedBindings())
      try data.write(to: fileURL, options: .atomic)
    } catch {
      telegramBotLogger.warning("Failed to save Telegram thread bindings: \(String(describing: error))")
    }
  }

  private func sortedBindings() -> [TelegramThreadBinding] {
    bindings.values.sorted { lhs, rhs in
      if lhs.target.chatID != rhs.target.chatID {
        return lhs.target.chatID < rhs.target.chatID
      }
      return (lhs.target.threadID ?? -1) < (rhs.target.threadID ?? -1)
    }
  }
}

struct TelegramPaneCapture: Equatable, Sendable {
  let viewportText: String
  let screenText: String?

  var readCaptureInput: ReadCaptureInput {
    ReadCaptureInput(viewportText: viewportText, screenText: screenText)
  }
}

private struct TelegramPendingPaneReply: Sendable {
  let token: String
  let target: TelegramBotTarget
  let replyToMessageID: Int
  let inputText: String
  let baseline: TelegramPaneCapture
  let worktreeID: Worktree.ID
  let paneID: UUID
  var observedBusy: Bool
}

@MainActor
struct TelegramBotUpdateProcessor {
  typealias Route = @MainActor @Sendable (CommandEnvelope) async -> CommandResponse
  typealias SendMessage = @MainActor @Sendable (_ target: TelegramBotTarget, _ text: String) async throws -> Void
  typealias SetMessageReaction =
    @MainActor @Sendable (_ target: TelegramBotTarget, _ messageID: Int, _ emoji: String) async throws -> Void
  typealias EditForumTopic = @MainActor @Sendable (_ target: TelegramBotTarget, _ name: String) async throws -> Void
  typealias RecordPendingReply =
    @MainActor @Sendable (
      _ target: TelegramBotTarget,
      _ messageID: Int,
      _ inputText: String,
      _ response: CommandResponse
    ) -> Void

  let configuration: TelegramBotConfiguration
  let parser: TelegramBotCommandParser
  let formatter: TelegramBotResponseFormatter
  let bindingStore: TelegramThreadBindingStore
  let route: Route
  let sendMessage: SendMessage
  let setMessageReaction: SetMessageReaction
  let editForumTopic: EditForumTopic
  let recordPendingReply: RecordPendingReply

  init(
    configuration: TelegramBotConfiguration,
    formatter: TelegramBotResponseFormatter = TelegramBotResponseFormatter(),
    bindingStore: TelegramThreadBindingStore = TelegramThreadBindingStore(fileURL: nil),
    route: @escaping Route,
    sendMessage: @escaping SendMessage,
    setMessageReaction: @escaping SetMessageReaction = { _, _, _ in
      throw TelegramBotClientError.invalidResponse
    },
    editForumTopic: @escaping EditForumTopic = { _, _ in
      throw TelegramBotClientError.invalidResponse
    },
    recordPendingReply: @escaping RecordPendingReply = { _, _, _, _ in }
  ) {
    let normalized = configuration.normalized
    self.configuration = normalized
    self.parser = TelegramBotCommandParser(
      defaultReadLines: normalized.defaultReadLines,
      requireExplicitPaneForWrite: normalized.requireExplicitPaneForWrite
    )
    self.formatter = formatter
    self.bindingStore = bindingStore
    self.route = route
    self.sendMessage = sendMessage
    self.setMessageReaction = setMessageReaction
    self.editForumTopic = editForumTopic
    self.recordPendingReply = recordPendingReply
  }

  func process(updates: [TelegramBotUpdate]) async -> Int? {
    var nextOffset: Int?
    let allowedUserIDs = Set(configuration.allowedUserIDs)

    for update in updates {
      nextOffset = max(nextOffset ?? 0, update.updateID + 1)
      guard let message = update.message,
        let user = message.from,
        let text = message.text
      else {
        continue
      }

      guard allowedUserIDs.contains(user.id) else {
        telegramBotLogger.info("Rejected Telegram command from unauthorized user_id=\(user.id)")
        continue
      }

      let target = message.target
      let boundSelector = bindingStore.binding(for: target)?.selector
      switch parser.parse(text: text, boundSelector: boundSelector) {
      case .message(let responseText):
        await send(target: target, text: responseText)

      case .binding(let command):
        await send(target: target, text: await handleBindingCommand(command, target: target))

      case .command(let request):
        telegramBotLogger.info("Executing Telegram command type=\(request.commandName)")
        let response = await route(request.envelope)
        if response.ok, let acknowledgement = request.acknowledgement {
          recordPendingReplyIfNeeded(request: request, response: response, target: target, messageID: message.messageID)
          await acknowledge(target: target, messageID: message.messageID, emoji: acknowledgement)
        } else {
          await send(target: target, text: formatter.format(response))
        }
      }
    }

    return nextOffset
  }

  private func recordPendingReplyIfNeeded(
    request: TelegramBotCommandRequest,
    response: CommandResponse,
    target: TelegramBotTarget,
    messageID: Int
  ) {
    guard case .send(let input) = request.envelope.command else { return }
    recordPendingReply(target, messageID, input.text, response)
  }

  private func handleBindingCommand(_ command: TelegramBotBindingCommand, target: TelegramBotTarget) async -> String {
    switch command {
    case .bindPane(let paneID):
      let selector = TargetSelector.pane(paneID)
      let displayName = await bindingDisplayName(for: selector) ?? Self.topicName(from: ["pane \(paneID)"])
      bindingStore.bind(target: target, selector: selector, displayName: displayName)
      await renameForumTopicIfNeeded(target: target, name: displayName)
      return "Bound this Telegram thread to pane \(paneID)."

    case .bindWorktree(let worktree):
      let selector = TargetSelector.worktree(worktree)
      let displayName = await bindingDisplayName(for: selector) ?? Self.topicName(from: ["worktree \(worktree)"])
      bindingStore.bind(target: target, selector: selector, displayName: displayName)
      await renameForumTopicIfNeeded(target: target, name: displayName)
      return "Bound this Telegram thread to worktree \(worktree)."

    case .unbind:
      if bindingStore.unbind(target: target) {
        return "Removed this Telegram thread binding."
      }
      return "This Telegram thread is not bound."

    case .showBinding:
      if let binding = bindingStore.binding(for: target) {
        return "This Telegram thread is bound to \(binding.displayName)."
      }
      return "This Telegram thread is not bound. Use /bind_pane <pane-id> or /bind_worktree <worktree>."
    }
  }

  private func bindingDisplayName(for selector: TargetSelector) async -> String? {
    if case .pane(let paneID) = selector,
      let agentName = await agentTopicName(forPaneID: paneID)
    {
      return agentName
    }
    return await listTopicName(for: selector)
  }

  private func agentTopicName(forPaneID paneID: String) async -> String? {
    let response = await route(CommandEnvelope(output: .json, command: .agents(AgentsInput())))
    guard response.ok,
      let data = response.data,
      let payload = try? data.decode(as: AgentsCommandPayload.self),
      let agent = payload.agents.first(where: { $0.id == paneID || $0.pane.id == paneID })
    else {
      return nil
    }

    return Self.topicName(from: [agent.project.name, agent.name, agent.project.branch])
  }

  private func listTopicName(for selector: TargetSelector) async -> String? {
    let response = await route(CommandEnvelope(output: .json, command: .list(ListInput())))
    guard response.ok,
      let data = response.data,
      let payload = try? data.decode(as: ListCommandPayload.self)
    else {
      return nil
    }

    switch selector {
    case .pane(let paneID):
      guard let item = payload.items.first(where: { $0.pane.id == paneID }) else { return nil }
      return Self.topicName(from: [item.worktree.name, item.pane.title])

    case .worktree(let worktree):
      guard
        let item = payload.items.first(where: { item in
          item.worktree.id == worktree || item.worktree.name == worktree || item.worktree.path == worktree
        })
      else {
        return nil
      }
      return Self.topicName(from: [item.worktree.name])

    case .auto(let value):
      if let paneItem = payload.items.first(where: { $0.pane.id == value }) {
        return Self.topicName(from: [paneItem.worktree.name, paneItem.pane.title])
      }
      guard
        let worktreeItem = payload.items.first(where: { item in
          item.worktree.id == value || item.worktree.name == value || item.worktree.path == value
        })
      else {
        return nil
      }
      return Self.topicName(from: [worktreeItem.worktree.name])

    case .tab, .none:
      return nil
    }
  }

  private func renameForumTopicIfNeeded(target: TelegramBotTarget, name: String) async {
    guard target.threadID != nil else { return }
    do {
      try await editForumTopic(target, name)
    } catch {
      telegramBotLogger.warning("Failed to rename Telegram forum topic: \(telegramBotLogMessage(for: error))")
    }
  }

  private static func topicName(from components: [String]) -> String {
    var normalizedComponents: [String] = []
    var seen: Set<String> = []

    for component in components {
      let normalized = component.split(whereSeparator: \.isWhitespace).joined(separator: " ")
      guard !normalized.isEmpty else { continue }
      let key = normalized.lowercased()
      guard !seen.contains(key) else { continue }
      seen.insert(key)
      normalizedComponents.append(normalized)
    }

    let joined = normalizedComponents.joined(separator: " - ")
    let fallback = joined.isEmpty ? "Prowl" : joined
    return String(fallback.prefix(128))
  }

  private func send(target: TelegramBotTarget, text: String) async {
    do {
      try await sendMessage(target, text)
    } catch {
      telegramBotLogger.warning("Failed to send Telegram message: \(telegramBotLogMessage(for: error))")
    }
  }

  private func acknowledge(target: TelegramBotTarget, messageID: Int, emoji: String) async {
    do {
      try await setMessageReaction(target, messageID, emoji)
    } catch {
      telegramBotLogger.warning("Failed to set Telegram reaction: \(telegramBotLogMessage(for: error))")
      await send(target: target, text: emoji)
    }
  }
}

@MainActor
final class TelegramBotRuntime {
  typealias Route = @MainActor @Sendable (CommandEnvelope) async -> CommandResponse
  typealias Sleep = @Sendable (Duration) async -> Void
  typealias CapturePane = @MainActor @Sendable (_ worktreeID: Worktree.ID, _ paneID: UUID) -> TelegramPaneCapture?

  private let client: TelegramBotClient
  private let route: Route
  private let sleep: Sleep
  private let capturePane: CapturePane
  private let bindingStore: TelegramThreadBindingStore
  private var task: Task<Void, Never>?
  private var pendingReplies: [UUID: TelegramPendingPaneReply] = [:]
  private var configuration: TelegramBotConfiguration = .init(
    enabled: false,
    token: nil,
    allowedUserIDs: [],
    defaultReadLines: 80,
    requireExplicitPaneForWrite: true
  )
  private var offset: Int?

  init(
    client: TelegramBotClient = .liveValue,
    route: @escaping Route,
    bindingStore: TelegramThreadBindingStore = TelegramThreadBindingStore(),
    sleep: @escaping Sleep = { duration in
      try? await Task.sleep(for: duration)
    },
    capturePane: @escaping CapturePane = { _, _ in nil }
  ) {
    self.client = client
    self.route = route
    self.bindingStore = bindingStore
    self.sleep = sleep
    self.capturePane = capturePane
  }

  deinit {
    task?.cancel()
  }

  func apply(configuration newConfiguration: TelegramBotConfiguration) {
    let normalized = newConfiguration.normalized
    guard normalized.canRun else {
      stop()
      configuration = normalized
      return
    }

    if normalized != configuration {
      stop()
      configuration = normalized
      start()
    } else if task == nil {
      start()
    }
  }

  func stop() {
    let wasRunning = task != nil
    task?.cancel()
    task = nil
    offset = nil
    pendingReplies.removeAll()
    if wasRunning {
      telegramBotLogger.info("Telegram bot stopped")
    }
  }

  func pollOnce(configuration: TelegramBotConfiguration, offset: Int?) async -> Int? {
    do {
      return try await pollOnceThrowing(configuration: configuration.normalized, offset: offset)
    } catch {
      telegramBotLogger.warning("Telegram poll failed: \(telegramBotLogMessage(for: error))")
      return offset
    }
  }

  private func start() {
    guard task == nil else { return }
    telegramBotLogger.info("Telegram bot started")
    task = Task { [weak self] in
      await self?.runLoop()
    }
  }

  private func runLoop() async {
    var backoffSeconds = 1
    while !Task.isCancelled {
      let currentConfiguration = configuration
      guard currentConfiguration.canRun else { return }
      do {
        offset = try await pollOnceThrowing(configuration: currentConfiguration, offset: offset)
        backoffSeconds = 1
      } catch {
        telegramBotLogger.warning("Telegram poll failed: \(telegramBotLogMessage(for: error))")
        await sleep(.seconds(backoffSeconds))
        backoffSeconds = min(backoffSeconds * 2, 60)
      }
    }
  }

  private func pollOnceThrowing(configuration: TelegramBotConfiguration, offset: Int?) async throws -> Int? {
    guard let token = configuration.activeToken else { return offset }
    let updates = try await client.getUpdates(token, offset, 30)
    guard !updates.isEmpty else { return offset }
    let processor = TelegramBotUpdateProcessor(
      configuration: configuration,
      bindingStore: bindingStore,
      route: route,
      sendMessage: { [client] target, text in
        try await client.sendMessage(token, target, text)
      },
      setMessageReaction: { [client] target, messageID, emoji in
        try await client.setMessageReaction(token, target, messageID, emoji)
      },
      editForumTopic: { [client] target, name in
        try await client.editForumTopic(token, target, name)
      },
      recordPendingReply: { [weak self] target, messageID, inputText, response in
        self?.recordPendingReply(
          token: token,
          target: target,
          messageID: messageID,
          inputText: inputText,
          response: response
        )
      }
    )
    return await processor.process(updates: updates) ?? offset
  }

  func agentEntryChanged(_ entry: ActiveAgentEntry) async {
    guard var pendingReply = pendingReplies[entry.surfaceID] else { return }

    switch entry.displayState {
    case .working, .blocked:
      pendingReply.observedBusy = true
      pendingReplies[entry.surfaceID] = pendingReply

    case .done, .idle:
      guard pendingReply.observedBusy else { return }
      pendingReplies.removeValue(forKey: entry.surfaceID)
      await sendPendingReplyAfterStable(pendingReply)
    }
  }

  func agentEntryRemoved(_ id: UUID) {
    pendingReplies.removeValue(forKey: id)
  }

  private func recordPendingReply(
    token: String,
    target: TelegramBotTarget,
    messageID: Int,
    inputText: String,
    response: CommandResponse
  ) {
    guard response.ok,
      let data = response.data,
      let payload = try? data.decode(as: SendCommandPayload.self),
      let paneID = UUID(uuidString: payload.target.pane.id),
      let baseline = capturePane(payload.target.worktree.id, paneID)
    else {
      return
    }

    pendingReplies[paneID] = TelegramPendingPaneReply(
      token: token,
      target: target,
      replyToMessageID: messageID,
      inputText: inputText,
      baseline: baseline,
      worktreeID: payload.target.worktree.id,
      paneID: paneID,
      observedBusy: false
    )
  }

  private func sendPendingReplyAfterStable(_ pendingReply: TelegramPendingPaneReply) async {
    await sleep(.milliseconds(800))
    guard let postCapture = capturePane(pendingReply.worktreeID, pendingReply.paneID) else { return }
    let captured = TerminalOutputDiff.diff(
      pre: pendingReply.baseline.readCaptureInput,
      post: postCapture.readCaptureInput,
      commandText: pendingReply.inputText
    )
    let replyText = telegramReplyText(from: captured.text)
    guard !replyText.isEmpty else { return }

    do {
      try await client.sendReplyMessage(
        pendingReply.token,
        pendingReply.target,
        replyText,
        pendingReply.replyToMessageID
      )
    } catch {
      telegramBotLogger.warning("Failed to send Telegram reply: \(telegramBotLogMessage(for: error))")
    }
  }
}

private func telegramReplyText(from text: String) -> String {
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return "" }

  let limit = 3_900
  guard trimmed.count > limit else { return trimmed }
  return "\(trimmed.prefix(limit))\n..."
}

private func telegramBotLogMessage(for error: Error) -> String {
  if let clientError = error as? TelegramBotClientError {
    switch clientError {
    case .invalidResponse:
      return "invalid_response"
    case .api(let errorCode, let description):
      if let errorCode {
        return "api_error code=\(errorCode) description=\(description)"
      }
      return "api_error description=\(description)"
    }
  }
  return "network_error"
}
