// ProwlShared/InputModels.swift
// Typed input models matching input.md contract

import Foundation

public struct OpenInput: Codable, Sendable {
  /// Normalized absolute path, or nil for bare `prowl` (bring to front).
  public let path: String?

  /// Invocation kind: "bare", "implicit-open", or "open-subcommand".
  /// Optional — handler derives a default if absent.
  public let invocation: String?

  /// `true` when the CLI had to launch Prowl before sending this command.
  /// The handler copies this value into the response's `app_launched` field.
  public let appLaunched: Bool

  public init(path: String? = nil, invocation: String? = nil, appLaunched: Bool = false) {
    self.path = path
    self.invocation = invocation
    self.appLaunched = appLaunched
  }
}

public struct ListInput: Codable, Sendable {
  public init() {}
}

public struct FocusInput: Codable, Sendable {
  public let selector: TargetSelector

  public init(selector: TargetSelector = .none) {
    self.selector = selector
  }
}

public enum InputSource: String, Codable, Sendable {
  case argv
  case stdin
}

public struct SendInput: Codable, Sendable {
  public let selector: TargetSelector
  public let text: String
  public let trailingEnter: Bool
  public let source: InputSource
  public let wait: Bool
  public let timeoutSeconds: Int?
  public let captureOutput: Bool

  enum CodingKeys: String, CodingKey {
    case selector
    case text
    case trailingEnter = "trailing_enter"
    case source
    case wait
    case timeoutSeconds = "timeout_seconds"
    case captureOutput = "capture_output"
  }

  public init(
    selector: TargetSelector = .none,
    text: String,
    trailingEnter: Bool = true,
    source: InputSource = .argv,
    wait: Bool = true,
    timeoutSeconds: Int? = nil,
    captureOutput: Bool = false
  ) {
    self.selector = selector
    self.text = text
    self.trailingEnter = trailingEnter
    self.source = source
    self.wait = wait
    self.timeoutSeconds = timeoutSeconds
    self.captureOutput = captureOutput
  }
}

public struct KeyInput: Codable, Sendable {
  public let selector: TargetSelector
  /// The user's original token after trimming (for `requested.token` in response).
  public let rawToken: String
  /// The canonical normalized token (for execution and `key.normalized` in response).
  public let token: String
  public let repeatCount: Int

  enum CodingKeys: String, CodingKey {
    case selector
    case rawToken = "raw_token"
    case token
    case repeatCount = "repeat_count"
  }

  public init(
    selector: TargetSelector = .none,
    rawToken: String,
    token: String,
    repeatCount: Int = 1
  ) {
    self.selector = selector
    self.rawToken = rawToken
    self.token = token
    self.repeatCount = repeatCount
  }
}

public struct ReadInput: Codable, Sendable {
  public let selector: TargetSelector
  public let last: Int?
  /// When true, the app re-reads the pane until its output stops changing before responding.
  public let waitStable: Bool
  /// Sampling interval in milliseconds while waiting for stable output (nil → app default).
  public let stableIntervalMs: Int?
  /// Output must stay unchanged for this many milliseconds to count as stable (nil → app default).
  public let stablePeriodMs: Int?
  /// Maximum seconds to keep waiting for stable output before returning the latest snapshot (nil → app default).
  public let waitTimeoutSeconds: Int?

  public init(
    selector: TargetSelector = .none,
    last: Int? = nil,
    waitStable: Bool = false,
    stableIntervalMs: Int? = nil,
    stablePeriodMs: Int? = nil,
    waitTimeoutSeconds: Int? = nil
  ) {
    self.selector = selector
    self.last = last
    self.waitStable = waitStable
    self.stableIntervalMs = stableIntervalMs
    self.stablePeriodMs = stablePeriodMs
    self.waitTimeoutSeconds = waitTimeoutSeconds
  }
}

public enum TabAction: String, Codable, Sendable {
  case create
  case close
}

public struct TabInput: Codable, Sendable {
  public let action: TabAction
  public let selector: TargetSelector
  public let path: String?

  public init(action: TabAction, selector: TargetSelector = .none, path: String? = nil) {
    self.action = action
    self.selector = selector
    self.path = path
  }
}

public enum PaneAction: String, Codable, Sendable {
  case close
}

public struct PaneInput: Codable, Sendable {
  public let action: PaneAction
  public let selector: TargetSelector

  public init(action: PaneAction, selector: TargetSelector = .none) {
    self.action = action
    self.selector = selector
  }
}
