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

@MainActor
struct TelegramBotUpdateProcessor {
  typealias Route = @MainActor @Sendable (CommandEnvelope) async -> CommandResponse
  typealias SendMessage = @MainActor @Sendable (_ target: TelegramBotTarget, _ text: String) async throws -> Void

  let configuration: TelegramBotConfiguration
  let parser: TelegramBotCommandParser
  let formatter: TelegramBotResponseFormatter
  let bindingStore: TelegramThreadBindingStore
  let route: Route
  let sendMessage: SendMessage

  init(
    configuration: TelegramBotConfiguration,
    formatter: TelegramBotResponseFormatter = TelegramBotResponseFormatter(),
    bindingStore: TelegramThreadBindingStore = TelegramThreadBindingStore(fileURL: nil),
    route: @escaping Route,
    sendMessage: @escaping SendMessage
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
        await send(target: target, text: handleBindingCommand(command, target: target))

      case .command(let request):
        telegramBotLogger.info("Executing Telegram command type=\(request.commandName)")
        let response = await route(request.envelope)
        await send(target: target, text: formatter.format(response))
      }
    }

    return nextOffset
  }

  private func handleBindingCommand(_ command: TelegramBotBindingCommand, target: TelegramBotTarget) -> String {
    switch command {
    case .bindPane(let paneID):
      bindingStore.bind(target: target, selector: .pane(paneID), displayName: "pane \(paneID)")
      return "Bound this Telegram thread to pane \(paneID)."

    case .bindWorktree(let worktree):
      bindingStore.bind(target: target, selector: .worktree(worktree), displayName: "worktree \(worktree)")
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

  private func send(target: TelegramBotTarget, text: String) async {
    do {
      try await sendMessage(target, text)
    } catch {
      telegramBotLogger.warning("Failed to send Telegram message: \(telegramBotLogMessage(for: error))")
    }
  }
}

@MainActor
final class TelegramBotRuntime {
  typealias Route = @MainActor @Sendable (CommandEnvelope) async -> CommandResponse
  typealias Sleep = @Sendable (Duration) async -> Void

  private let client: TelegramBotClient
  private let route: Route
  private let sleep: Sleep
  private let bindingStore: TelegramThreadBindingStore
  private var task: Task<Void, Never>?
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
    }
  ) {
    self.client = client
    self.route = route
    self.bindingStore = bindingStore
    self.sleep = sleep
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
    guard task != nil else { return }
    task?.cancel()
    task = nil
    offset = nil
    telegramBotLogger.info("Telegram bot stopped")
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
      }
    )
    return await processor.process(updates: updates) ?? offset
  }
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
