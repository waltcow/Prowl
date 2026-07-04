import Dependencies
import Foundation

nonisolated struct TelegramBotUser: Codable, Equatable, Sendable {
  let id: Int64
  let isBot: Bool
  let firstName: String
  let username: String?

  enum CodingKeys: String, CodingKey {
    case id
    case isBot = "is_bot"
    case firstName = "first_name"
    case username
  }
}

nonisolated struct TelegramBotChat: Codable, Equatable, Sendable {
  let id: Int64
}

nonisolated struct TelegramBotTarget: Codable, Equatable, Hashable, Sendable {
  let chatID: Int64
  let threadID: Int?
}

nonisolated struct TelegramBotMessage: Codable, Equatable, Sendable {
  let messageID: Int
  let messageThreadID: Int?
  let from: TelegramBotUser?
  let chat: TelegramBotChat
  let text: String?

  init(
    messageID: Int,
    messageThreadID: Int? = nil,
    from: TelegramBotUser?,
    chat: TelegramBotChat,
    text: String?
  ) {
    self.messageID = messageID
    self.messageThreadID = messageThreadID
    self.from = from
    self.chat = chat
    self.text = text
  }

  var target: TelegramBotTarget {
    TelegramBotTarget(chatID: chat.id, threadID: messageThreadID)
  }

  enum CodingKeys: String, CodingKey {
    case messageID = "message_id"
    case messageThreadID = "message_thread_id"
    case from
    case chat
    case text
  }
}

nonisolated struct TelegramBotUpdate: Codable, Equatable, Sendable {
  let updateID: Int
  let message: TelegramBotMessage?

  enum CodingKeys: String, CodingKey {
    case updateID = "update_id"
    case message
  }
}

nonisolated struct TelegramBotCommand: Codable, Equatable, Sendable {
  let command: String
  let description: String
}

nonisolated enum TelegramBotCommandCatalog {
  static let commands: [TelegramBotCommand] = [
    TelegramBotCommand(command: "agents", description: "Show current agent roster"),
    TelegramBotCommand(command: "list", description: "Show worktrees, tabs, and panes"),
    TelegramBotCommand(command: "read", description: "Read recent terminal output"),
    TelegramBotCommand(command: "focus", description: "Focus a pane in Prowl"),
    TelegramBotCommand(command: "send", description: "Send text and Enter to a pane"),
    TelegramBotCommand(command: "key", description: "Send a supported key token"),
    TelegramBotCommand(command: "tab_create", description: "Create a tab in a worktree"),
    TelegramBotCommand(command: "pane_close", description: "Close a pane by ID"),
    TelegramBotCommand(command: "tab_close", description: "Close a tab by ID"),
    TelegramBotCommand(command: "bind_pane", description: "Bind this thread to a pane"),
    TelegramBotCommand(command: "bind_worktree", description: "Bind this thread to a worktree"),
    TelegramBotCommand(command: "where", description: "Show this thread binding"),
    TelegramBotCommand(command: "unbind", description: "Remove this thread binding"),
    TelegramBotCommand(command: "help", description: "Show available commands"),
  ]
}

enum TelegramBotClientError: Error, Equatable, Sendable {
  case invalidResponse
  case api(errorCode: Int?, description: String)
}

struct TelegramBotClient: Sendable, DependencyKey {
  var getMe: @Sendable (_ token: String) async throws -> TelegramBotUser
  var getUpdates: @Sendable (_ token: String, _ offset: Int?, _ timeout: Int) async throws -> [TelegramBotUpdate]
  var sendMessage: @Sendable (_ token: String, _ target: TelegramBotTarget, _ text: String) async throws -> Void
  var sendReplyMessage:
    @Sendable (_ token: String, _ target: TelegramBotTarget, _ text: String, _ replyToMessageID: Int) async throws
      -> Void
  var editForumTopic: @Sendable (_ token: String, _ target: TelegramBotTarget, _ name: String) async throws -> Void
  var setMessageReaction:
    @Sendable (_ token: String, _ target: TelegramBotTarget, _ messageID: Int, _ emoji: String) async throws -> Void
  var setMyCommands: @Sendable (_ token: String, _ commands: [TelegramBotCommand]) async throws -> Void

  static let liveValue = TelegramBotClient(
    getMe: { token in
      try await TelegramBotHTTPClient.request(
        token: token,
        method: "getMe",
        queryItems: []
      )
    },
    getUpdates: { token, offset, timeout in
      var queryItems = [
        URLQueryItem(name: "timeout", value: String(timeout)),
        URLQueryItem(name: "allowed_updates", value: #"["message"]"#),
      ]
      if let offset {
        queryItems.append(URLQueryItem(name: "offset", value: String(offset)))
      }
      return try await TelegramBotHTTPClient.request(
        token: token,
        method: "getUpdates",
        queryItems: queryItems
      )
    },
    sendMessage: { token, target, text in
      try await TelegramBotClient.postMessage(token: token, target: target, text: text, replyToMessageID: nil)
    },
    sendReplyMessage: { token, target, text, replyToMessageID in
      try await TelegramBotClient.postMessage(
        token: token,
        target: target,
        text: text,
        replyToMessageID: replyToMessageID
      )
    },
    editForumTopic: { token, target, name in
      guard let threadID = target.threadID else { return }
      let _: Bool = try await TelegramBotHTTPClient.request(
        token: token,
        method: "editForumTopic",
        queryItems: [
          URLQueryItem(name: "chat_id", value: String(target.chatID)),
          URLQueryItem(name: "message_thread_id", value: String(threadID)),
          URLQueryItem(name: "name", value: name),
        ],
        httpMethod: "POST"
      )
    },
    setMessageReaction: { token, target, messageID, emoji in
      let data = try JSONEncoder().encode([TelegramReactionTypeEmoji(emoji: emoji)])
      guard let reaction = String(data: data, encoding: .utf8) else {
        throw TelegramBotClientError.invalidResponse
      }
      let _: Bool = try await TelegramBotHTTPClient.request(
        token: token,
        method: "setMessageReaction",
        queryItems: [
          URLQueryItem(name: "chat_id", value: String(target.chatID)),
          URLQueryItem(name: "message_id", value: String(messageID)),
          URLQueryItem(name: "reaction", value: reaction),
        ],
        httpMethod: "POST"
      )
    },
    setMyCommands: { token, commands in
      let data = try JSONEncoder().encode(commands)
      guard let json = String(data: data, encoding: .utf8) else {
        throw TelegramBotClientError.invalidResponse
      }
      let _: Bool = try await TelegramBotHTTPClient.request(
        token: token,
        method: "setMyCommands",
        queryItems: [URLQueryItem(name: "commands", value: json)],
        httpMethod: "POST"
      )
    }
  )

  static let testValue = TelegramBotClient(
    getMe: { _ in
      throw TelegramBotClientError.invalidResponse
    },
    getUpdates: { _, _, _ in
      throw TelegramBotClientError.invalidResponse
    },
    sendMessage: { _, _, _ in
      throw TelegramBotClientError.invalidResponse
    },
    sendReplyMessage: { _, _, _, _ in
      throw TelegramBotClientError.invalidResponse
    },
    editForumTopic: { _, _, _ in
      throw TelegramBotClientError.invalidResponse
    },
    setMessageReaction: { _, _, _, _ in
      throw TelegramBotClientError.invalidResponse
    },
    setMyCommands: { _, _ in
      throw TelegramBotClientError.invalidResponse
    }
  )
}

extension TelegramBotClient {
  fileprivate static func postMessage(
    token: String,
    target: TelegramBotTarget,
    text: String,
    replyToMessageID: Int?
  ) async throws {
    var queryItems = [
      URLQueryItem(name: "chat_id", value: String(target.chatID)),
      URLQueryItem(name: "text", value: text),
    ]
    if let threadID = target.threadID {
      queryItems.append(URLQueryItem(name: "message_thread_id", value: String(threadID)))
    }
    if let replyToMessageID {
      let data = try JSONEncoder().encode(
        TelegramReplyParameters(messageID: replyToMessageID, allowSendingWithoutReply: true)
      )
      guard let replyParameters = String(data: data, encoding: .utf8) else {
        throw TelegramBotClientError.invalidResponse
      }
      queryItems.append(URLQueryItem(name: "reply_parameters", value: replyParameters))
    }
    let _: TelegramBotMessage = try await TelegramBotHTTPClient.request(
      token: token,
      method: "sendMessage",
      queryItems: queryItems,
      httpMethod: "POST"
    )
  }
}

extension DependencyValues {
  var telegramBotClient: TelegramBotClient {
    get { self[TelegramBotClient.self] }
    set { self[TelegramBotClient.self] = newValue }
  }
}

private enum TelegramBotHTTPClient {
  static func request<Result: Decodable>(
    token: String,
    method: String,
    queryItems: [URLQueryItem],
    httpMethod: String = "GET"
  ) async throws -> Result {
    guard var components = URLComponents(string: "https://api.telegram.org/bot\(token)/\(method)") else {
      throw TelegramBotClientError.invalidResponse
    }

    var request: URLRequest
    if httpMethod == "GET" {
      components.queryItems = queryItems.isEmpty ? nil : queryItems
      guard let url = components.url else { throw TelegramBotClientError.invalidResponse }
      request = URLRequest(url: url)
    } else {
      guard let url = components.url else { throw TelegramBotClientError.invalidResponse }
      request = URLRequest(url: url)
      request.httpMethod = httpMethod
      request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
      request.httpBody = formURLEncoded(queryItems).data(using: .utf8)
    }

    let (data, _) = try await URLSession.shared.data(for: request)
    let decoded = try JSONDecoder().decode(TelegramBotAPIResponse<Result>.self, from: data)
    if decoded.success, let result = decoded.result {
      return result
    }
    throw TelegramBotClientError.api(
      errorCode: decoded.errorCode,
      description: decoded.description ?? "Telegram Bot API request failed."
    )
  }

  private static func formURLEncoded(_ queryItems: [URLQueryItem]) -> String {
    queryItems.map { item in
      let name = item.name.addingPercentEncoding(withAllowedCharacters: .telegramFormAllowed) ?? item.name
      let value = (item.value ?? "").addingPercentEncoding(withAllowedCharacters: .telegramFormAllowed) ?? ""
      return "\(name)=\(value)"
    }
    .joined(separator: "&")
  }
}

extension CharacterSet {
  fileprivate static let telegramFormAllowed: CharacterSet = {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&=+")
    return allowed
  }()
}

nonisolated private struct TelegramBotAPIResponse<Result: Decodable>: Decodable {
  let success: Bool
  let result: Result?
  let description: String?
  let errorCode: Int?

  enum CodingKeys: String, CodingKey {
    case success = "ok"
    case result
    case description
    case errorCode = "error_code"
  }
}

nonisolated private struct TelegramReplyParameters: Encodable {
  let messageID: Int
  let allowSendingWithoutReply: Bool

  enum CodingKeys: String, CodingKey {
    case messageID = "message_id"
    case allowSendingWithoutReply = "allow_sending_without_reply"
  }
}

nonisolated private struct TelegramReactionTypeEmoji: Encodable {
  let type = "emoji"
  let emoji: String
}
