import Foundation

/// Project ecosystems Prowl can recognize from a worktree's top-level files,
/// used to pick a fitting app when the open action is set to Automatic.
enum WorktreeProjectKind: CaseIterable {
  case apple
  case android
  case dotnet
  case java
  case golang
  case rust
  case cpp
  case php
  case ruby
  case python
  case web

  /// Detects the project kind from a single shallow listing of `directory`.
  /// Checks run from the most specific marker to the least: `package.json` is
  /// last because nearly any repo can carry one for tooling, while an
  /// `.xcodeproj` or Gradle script identifies the project unambiguously.
  static func detect(at directory: URL, fileManager: FileManager = .default) -> WorktreeProjectKind? {
    guard let entries = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
      return nil
    }
    let names = Set(entries.map { $0.lowercased() })
    func hasFile(withExtension ext: String) -> Bool {
      names.contains { $0.hasSuffix(".\(ext)") }
    }
    if hasFile(withExtension: "xcodeproj") || hasFile(withExtension: "xcworkspace")
      || names.contains("package.swift") || names.contains("project.swift")
    {
      return .apple
    }
    if names.contains("settings.gradle") || names.contains("settings.gradle.kts")
      || names.contains("build.gradle") || names.contains("build.gradle.kts")
      || names.contains("gradlew")
    {
      return .android
    }
    if hasFile(withExtension: "sln") || hasFile(withExtension: "csproj") {
      return .dotnet
    }
    if names.contains("pom.xml") {
      return .java
    }
    if names.contains("go.mod") {
      return .golang
    }
    if names.contains("cargo.toml") {
      return .rust
    }
    if names.contains("cmakelists.txt") {
      return .cpp
    }
    if names.contains("composer.json") {
      return .php
    }
    if names.contains("gemfile") {
      return .ruby
    }
    if names.contains("pyproject.toml") || names.contains("setup.py")
      || names.contains("requirements.txt") || names.contains("pipfile")
    {
      return .python
    }
    if names.contains("package.json") {
      return .web
    }
    return nil
  }

  /// Apps to try before `OpenWorktreeAction.defaultPriority` when resolving
  /// the Automatic open action for this project kind.
  var preferredActions: [OpenWorktreeAction] {
    switch self {
    case .apple: [.xcode]
    case .android: [.androidStudio, .intellij]
    case .dotnet: [.rider]
    case .java: [.intellij]
    case .golang: [.goland]
    case .rust: [.rustrover]
    case .cpp: [.clion]
    case .php: [.phpstorm]
    case .ruby: [.rubymine]
    case .python: [.pycharm]
    case .web: [.webstorm]
    }
  }
}
