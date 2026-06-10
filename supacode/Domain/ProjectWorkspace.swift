import Foundation

nonisolated enum ProjectWorkspaceRepositorySourceKind: String, Codable, Equatable, Hashable, Sendable {
  case remote
  case localRepository = "local_repository"
  case bareRepository = "bare_repository"
  case existingPath = "existing_path"

  var supportsLinkCheckout: Bool {
    switch self {
    case .existingPath, .localRepository:
      return true
    case .remote, .bareRepository:
      return false
    }
  }

  var defaultCheckoutMode: ProjectWorkspaceRepositoryCheckoutMode {
    switch self {
    case .existingPath, .localRepository:
      return .link
    case .bareRepository:
      return .createBranch
    case .remote:
      return .useExistingRef
    }
  }

  func localSourceURL(from sourceLocation: String) -> URL? {
    switch self {
    case .existingPath, .localRepository, .bareRepository:
      let trimmed = sourceLocation.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        return nil
      }
      return URL(fileURLWithPath: trimmed).standardizedFileURL
    case .remote:
      return nil
    }
  }
}

nonisolated enum ProjectWorkspaceRepositoryCheckoutMode: String, Codable, Equatable, Hashable, Sendable {
  case link
  case createBranch = "create_branch"
  case useExistingRef = "use_existing_ref"
}

nonisolated enum ProjectWorkspaceRepositoryCheckout: Equatable, Hashable, Sendable {
  case link
  case createBranch(branchName: String, baseRef: String?)
  case useExistingRef(String)
}

nonisolated struct ProjectWorkspaceCreationRepository: Equatable, Hashable, Sendable, Identifiable {
  var id: String
  var name: String
  var path: String?
  var sourceKind: ProjectWorkspaceRepositorySourceKind
  var sourceLocation: String
  var checkoutMode: ProjectWorkspaceRepositoryCheckoutMode
  var branchName: String?
  var baseRef: String?
  var baseRefOptions: [GitBranchRefOption]

  init(
    id: String,
    name: String,
    rootURL: URL,
    checkoutMode: ProjectWorkspaceRepositoryCheckoutMode? = nil,
    branchName: String? = nil,
    path: String? = nil,
    baseRef: String? = nil,
    baseRefOptions: [GitBranchRefOption] = []
  ) {
    let normalizedURL = rootURL.standardizedFileURL
    self.id = id
    self.name = name
    self.path = path
    sourceKind = .existingPath
    sourceLocation = normalizedURL.path(percentEncoded: false)
    self.checkoutMode = checkoutMode ?? ProjectWorkspaceRepositorySourceKind.existingPath.defaultCheckoutMode
    self.branchName = branchName
    self.baseRef = baseRef
    self.baseRefOptions = Self.normalizedBaseRefOptions(baseRefOptions)
  }

  init(
    id: String,
    name: String,
    sourceKind: ProjectWorkspaceRepositorySourceKind,
    sourceLocation: String,
    checkoutMode: ProjectWorkspaceRepositoryCheckoutMode? = nil,
    branchName: String? = nil,
    baseRef: String? = nil,
    path: String? = nil,
    baseRefOptions: [GitBranchRefOption] = []
  ) {
    self.id = id
    self.name = name
    self.path = path
    self.sourceKind = sourceKind
    self.sourceLocation = sourceLocation
    self.checkoutMode = checkoutMode ?? sourceKind.defaultCheckoutMode
    self.branchName = branchName
    self.baseRef = baseRef
    self.baseRefOptions = Self.normalizedBaseRefOptions(baseRefOptions)
  }

  var localSourceURL: URL? {
    sourceKind.localSourceURL(from: sourceLocation)
  }

  nonisolated static func baseRefOptions(
    automaticBaseRef: String?,
    options: [GitBranchRefOption]
  ) -> [GitBranchRefOption] {
    var values: [GitBranchRefOption] = []
    if let automaticBaseRef {
      let trimmed = automaticBaseRef.trimmingCharacters(in: .whitespacesAndNewlines)
      let kind = options.first { $0.ref == trimmed }?.kind ?? .local
      values.append(GitBranchRefOption(ref: automaticBaseRef, kind: kind))
    }
    values += options
    return normalizedBaseRefOptions(values)
  }

  nonisolated static func preferredBaseRef(automaticBaseRef: String?, options: [GitBranchRefOption]) -> String? {
    let refs = Set(options.map(\.ref))
    if let trimmed = automaticBaseRef?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty,
      refs.contains(trimmed)
    {
      return trimmed
    }
    return ["main", "master", "origin/main", "origin/master"].first { refs.contains($0) }
      ?? options.first?.ref
  }

  nonisolated static func normalizedBaseRefOptions(_ values: [GitBranchRefOption]) -> [GitBranchRefOption] {
    var seen = Set<String>()
    var result: [GitBranchRefOption] = []
    for value in values {
      let trimmed = value.ref.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, seen.insert(trimmed).inserted else {
        continue
      }
      result.append(GitBranchRefOption(ref: trimmed, kind: value.kind))
    }
    return result
  }
}

nonisolated struct ProjectWorkspaceRepositoryPlan: Equatable, Sendable, Identifiable {
  var id: String
  var name: String
  var path: String?
  var sourceKind: ProjectWorkspaceRepositorySourceKind
  var sourceLocation: String
  var checkout: ProjectWorkspaceRepositoryCheckout

  var localSourceURL: URL? {
    sourceKind.localSourceURL(from: sourceLocation)
  }
}

nonisolated struct ProjectWorkspaceCreationDraft: Equatable, Sendable {
  var title: String
  var rootURL: URL
  var repositories: [ProjectWorkspaceRepositoryPlan]

  init(
    title: String,
    rootURL: URL,
    repositories: [ProjectWorkspaceRepositoryPlan]
  ) {
    self.title = title
    self.rootURL = rootURL.standardizedFileURL
    self.repositories = repositories
  }
}

nonisolated struct ProjectWorkspaceCreationRequest: Equatable, Sendable {
  var draft: ProjectWorkspaceCreationDraft
  var createdAt: Date
}

nonisolated struct ProjectWorkspaceGitCommand: Equatable, Sendable {
  var arguments: [String]
  var currentDirectoryURL: URL?

  var displayCommand: String {
    (["git"] + arguments).joined(separator: " ")
  }
}

nonisolated struct ProjectWorkspaceGitRunner: Sendable {
  var run: @Sendable (ProjectWorkspaceGitCommand) async throws -> Void
}

nonisolated enum ProjectWorkspaceCreationError: LocalizedError, Equatable, Sendable {
  case missingTitle
  case missingPath
  case notEnoughRepositories
  case missingRepositoryName
  case missingRepositorySource(String)
  case missingBranchName(String)
  case missingExistingRef(String)
  case linkCheckoutUnsupported(String)
  case destinationIsFile(String)
  case workspaceAlreadyExists(String)
  case repositoryDoesNotExist(String)
  case linkAlreadyExists(String)
  case gitCommandFailed(command: String, message: String)

  var errorDescription: String? {
    switch self {
    case .missingTitle:
      return "Workspace title required."
    case .missingPath:
      return "Workspace folder required."
    case .notEnoughRepositories:
      return "Select at least two repositories."
    case .missingRepositoryName:
      return "Repository name required."
    case .missingRepositorySource(let name):
      return "Source required for \(name)."
    case .missingBranchName(let name):
      return "Branch name required for \(name)."
    case .missingExistingRef(let name):
      return "Choose an existing branch for \(name)."
    case .linkCheckoutUnsupported(let name):
      return "Link is not available for \(name)."
    case .destinationIsFile(let path):
      return "\(path) is a file. Choose a folder path instead."
    case .workspaceAlreadyExists(let path):
      return "\(path) already contains a Prowl workspace."
    case .repositoryDoesNotExist(let path):
      return "\(path) does not exist."
    case .linkAlreadyExists(let path):
      return "\(path) already exists."
    case .gitCommandFailed(let command, let message):
      if message.isEmpty {
        return "Git command failed: \(command)"
      }
      return "Git command failed: \(command)\n\(message)"
    }
  }
}

nonisolated struct ProjectWorkspaceRepositoryEntry: Codable, Equatable, Hashable, Sendable, Identifiable {
  var id: String
  var name: String
  var role: String?
  var path: String
  var sourceKind: ProjectWorkspaceRepositorySourceKind
  var sourceLocation: String?
  var branchName: String?
  var baseRef: String?

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case role
    case path
    case sourceKind = "source_kind"
    case sourceLocation = "source_location"
    case branchName = "branch_name"
    case baseRef = "base_ref"
  }

  init(
    id: String = "",
    name: String = "",
    role: String? = nil,
    path: String = "",
    sourceKind: ProjectWorkspaceRepositorySourceKind = .existingPath,
    sourceLocation: String? = nil,
    branchName: String? = nil,
    baseRef: String? = nil
  ) {
    self.id = id
    self.name = name
    self.role = role
    self.path = path
    self.sourceKind = sourceKind
    self.sourceLocation = sourceLocation
    self.branchName = branchName
    self.baseRef = baseRef
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    role = try container.decodeIfPresent(String.self, forKey: .role)
    path =
      try container.decodeIfPresent(String.self, forKey: .path)
      ?? name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      ?? id.trimmingCharacters(in: .whitespacesAndNewlines)
    sourceKind =
      try container.decodeIfPresent(ProjectWorkspaceRepositorySourceKind.self, forKey: .sourceKind)
      ?? .existingPath
    sourceLocation = try container.decodeIfPresent(String.self, forKey: .sourceLocation)
    branchName = try container.decodeIfPresent(String.self, forKey: .branchName)
    baseRef = try container.decodeIfPresent(String.self, forKey: .baseRef)
  }

  func resolvedURL(relativeTo workspaceRootURL: URL) -> URL {
    let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedPath.hasPrefix("/") {
      return URL(fileURLWithPath: trimmedPath).standardizedFileURL
    }
    return workspaceRootURL.appending(path: trimmedPath).standardizedFileURL
  }
}

nonisolated struct ProjectWorkspace: Codable, Equatable, Hashable, Sendable {
  typealias RepositorySourceKind = ProjectWorkspaceRepositorySourceKind
  typealias RepositoryEntry = ProjectWorkspaceRepositoryEntry

  nonisolated static let metadataDirectoryName = ".prowl"
  nonisolated static let metadataFileName = "workspace.json"
  nonisolated private static let log = SupaLogger("workspace")

  var id: String
  var title: String
  var description: String
  var taskLinks: [String]
  var repositories: [RepositoryEntry]
  var createdAt: Date?
  var updatedAt: Date?

  enum CodingKeys: String, CodingKey {
    case id
    case title
    case description
    case taskLinks = "task_links"
    case repositories
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }

  init(
    id: String = "",
    title: String = "",
    description: String = "",
    taskLinks: [String] = [],
    repositories: [RepositoryEntry] = [],
    createdAt: Date? = nil,
    updatedAt: Date? = nil
  ) {
    self.id = id
    self.title = title
    self.description = description
    self.taskLinks = taskLinks
    self.repositories = repositories
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
    title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
    description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
    taskLinks = try container.decodeIfPresent([String].self, forKey: .taskLinks) ?? []
    repositories = try container.decodeIfPresent([RepositoryEntry].self, forKey: .repositories) ?? []
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
    updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
  }

  static func metadataURL(for rootURL: URL) -> URL {
    rootURL
      .appending(path: metadataDirectoryName)
      .appending(path: metadataFileName)
  }

  static func load(from rootURL: URL) -> ProjectWorkspace? {
    let metadataURL = metadataURL(for: rootURL)
    guard let data = try? Data(contentsOf: metadataURL) else {
      return nil
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var workspace: ProjectWorkspace
    do {
      workspace = try decoder.decode(ProjectWorkspace.self, from: data)
    } catch {
      log.warning(
        "Ignoring malformed workspace metadata at \(metadataURL.path(percentEncoded: false)): \(error)"
      )
      return nil
    }
    let normalizedRoot = rootURL.standardizedFileURL.path(percentEncoded: false)
    if workspace.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      workspace.id = normalizedRoot
    }
    if workspace.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      workspace.title = rootURL.lastPathComponent.isEmpty ? normalizedRoot : rootURL.lastPathComponent
    }
    return workspace.normalized(relativeTo: rootURL)
  }

  func normalized(relativeTo rootURL: URL) -> ProjectWorkspace {
    var copy = self
    let normalizedRoot = rootURL.standardizedFileURL.path(percentEncoded: false)
    if copy.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      copy.id = normalizedRoot
    }
    copy.title = copy.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if copy.title.isEmpty {
      copy.title = rootURL.lastPathComponent.isEmpty ? normalizedRoot : rootURL.lastPathComponent
    }
    copy.description = copy.description.trimmingCharacters(in: .whitespacesAndNewlines)
    copy.taskLinks = copy.taskLinks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    copy.repositories = copy.repositories.map { entry in
      var entry = entry
      entry.id = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
      entry.name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
      entry.path = entry.path.trimmingCharacters(in: .whitespacesAndNewlines)
      if entry.id.isEmpty {
        entry.id = entry.path.isEmpty ? entry.name : entry.path
      }
      if entry.name.isEmpty {
        let resolvedURL = entry.resolvedURL(relativeTo: rootURL)
        entry.name = resolvedURL.lastPathComponent.isEmpty ? entry.id : resolvedURL.lastPathComponent
      }
      entry.role = entry.role?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      entry.sourceLocation = entry.sourceLocation?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      entry.branchName = entry.branchName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      entry.baseRef = entry.baseRef?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      return entry
    }
    return copy
  }

  static func create(
    _ request: ProjectWorkspaceCreationRequest,
    fileManager: FileManager = .default,
    gitRunner: ProjectWorkspaceGitRunner
  ) async throws -> ProjectWorkspace {
    let title = request.draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      throw ProjectWorkspaceCreationError.missingTitle
    }
    guard request.draft.repositories.count >= 2 else {
      throw ProjectWorkspaceCreationError.notEnoughRepositories
    }
    let rootPath = normalizedPath(request.draft.rootURL, resolvingSymlinks: false)
    guard !rootPath.isEmpty else {
      throw ProjectWorkspaceCreationError.missingPath
    }
    let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL

    var ledger = MaterializationLedger()
    do {
      var isDirectory = ObjCBool(false)
      if fileManager.fileExists(atPath: rootPath, isDirectory: &isDirectory) {
        guard isDirectory.boolValue else {
          throw ProjectWorkspaceCreationError.destinationIsFile(rootPath)
        }
      } else {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        ledger.createdRoot = true
      }

      let metadataDirectoryURL = rootURL.appending(path: metadataDirectoryName, directoryHint: .isDirectory)
      let metadataPath = metadataDirectoryURL.path(percentEncoded: false)
      let metadataURL = metadataURL(for: rootURL)
      if fileManager.fileExists(atPath: metadataURL.path(percentEncoded: false)) {
        throw ProjectWorkspaceCreationError.workspaceAlreadyExists(rootPath)
      }
      if !fileManager.fileExists(atPath: metadataPath) {
        try fileManager.createDirectory(at: metadataDirectoryURL, withIntermediateDirectories: true)
        ledger.createdMetadataDirectory = true
      }

      var entries: [RepositoryEntry] = []
      for repository in request.draft.repositories {
        let entry = try await materialize(
          repository,
          workspaceRootURL: rootURL,
          ledger: &ledger,
          fileManager: fileManager,
          gitRunner: gitRunner
        )
        entries.append(entry)
      }

      let workspace = ProjectWorkspace(
        id: rootPath,
        title: title,
        repositories: entries,
        createdAt: request.createdAt,
        updatedAt: request.createdAt
      )
      .normalized(relativeTo: rootURL)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      try encoder.encode(workspace).write(to: metadataURL, options: .atomic)
      ledger.createdURLs.append(metadataURL)
      return workspace
    } catch {
      await rollback(ledger, rootURL: rootURL, fileManager: fileManager, gitRunner: gitRunner)
      throw error
    }
  }

  private struct MaterializationLedger: Sendable {
    var occupiedNames: Set<String> = []
    var createdURLs: [URL] = []
    var cleanupCommands: [ProjectWorkspaceGitCommand] = []
    var createdRoot = false
    var createdMetadataDirectory = false
  }

  // Rollback runs in a detached task so it survives cooperative cancellation of
  // the surrounding effect: a cancelled parent task would otherwise SIGTERM the
  // cleanup git subprocesses before they finish.
  private static func rollback(
    _ ledger: MaterializationLedger,
    rootURL: URL,
    fileManager: FileManager,
    gitRunner: ProjectWorkspaceGitRunner
  ) async {
    nonisolated(unsafe) let fileManager = fileManager
    let task = Task.detached {
      for command in ledger.cleanupCommands.reversed() {
        do {
          try await gitRunner.run(command)
        } catch {
          log.warning("Workspace rollback command failed: \(command.displayCommand): \(error)")
        }
      }
      let removableURLs =
        ledger.createdURLs.reversed()
        + (ledger.createdRoot
          ? [rootURL]
          : ledger.createdMetadataDirectory
            ? [rootURL.appending(path: metadataDirectoryName, directoryHint: .isDirectory)]
            : [])
      for url in removableURLs {
        let path = url.path(percentEncoded: false)
        guard fileManager.fileExists(atPath: path) || (try? url.checkResourceIsReachable()) == true else {
          continue
        }
        do {
          try fileManager.removeItem(at: url)
        } catch {
          log.warning("Workspace rollback could not remove \(path): \(error)")
        }
      }
    }
    await task.value
  }

  static func defaultWorkspaceFolderName(for title: String) -> String {
    let sanitized = sanitizedWorkspaceComponent(title)
    return sanitized.isEmpty ? "workspace" : sanitized
  }

  private static func materialize(
    _ repository: ProjectWorkspaceRepositoryPlan,
    workspaceRootURL: URL,
    ledger: inout MaterializationLedger,
    fileManager: FileManager,
    gitRunner: ProjectWorkspaceGitRunner
  ) async throws -> RepositoryEntry {
    let name = repositoryDisplayName(repository)
    guard !name.isEmpty else {
      throw ProjectWorkspaceCreationError.missingRepositoryName
    }
    let sourceLocation = repository.sourceLocation.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sourceLocation.isEmpty else {
      throw ProjectWorkspaceCreationError.missingRepositorySource(name)
    }
    let checkout = try validatedCheckout(repository.checkout, sourceKind: repository.sourceKind, name: name)
    let workspacePath = uniqueRepositoryPath(
      for: repository,
      displayName: name,
      occupiedNames: &ledger.occupiedNames
    )
    let destinationURL = workspaceRootURL.appending(path: workspacePath, directoryHint: .isDirectory)
    let destinationPath = normalizedPath(destinationURL, resolvingSymlinks: false)
    guard !fileManager.fileExists(atPath: destinationPath) else {
      throw ProjectWorkspaceCreationError.linkAlreadyExists(destinationPath)
    }

    let normalizedSourceLocation: String
    switch repository.sourceKind {
    case .existingPath, .localRepository:
      let sourcePath = try localRepositoryPath(sourceLocation: sourceLocation, fileManager: fileManager)
      switch checkout {
      case .link:
        let sourceURL = URL(fileURLWithPath: sourcePath, isDirectory: true).standardizedFileURL
        try fileManager.createSymbolicLink(at: destinationURL, withDestinationURL: sourceURL)
        ledger.createdURLs.append(destinationURL)
      case .createBranch, .useExistingRef:
        try await gitRunner.run(
          worktreeAddCommand(checkout, sourcePath: sourcePath, destinationPath: destinationPath)
        )
        ledger.createdURLs.append(destinationURL)
        ledger.cleanupCommands.append(
          worktreeRemoveCommand(sourcePath: sourcePath, destinationPath: destinationPath)
        )
      }
      normalizedSourceLocation = sourcePath

    case .remote:
      try await gitRunner.run(
        ProjectWorkspaceGitCommand(
          arguments: ["clone", "--end-of-options", sourceLocation, destinationPath],
          currentDirectoryURL: workspaceRootURL
        )
      )
      ledger.createdURLs.append(destinationURL)
      if let checkoutCommand = remoteCheckoutCommand(checkout, destinationPath: destinationPath) {
        try await gitRunner.run(checkoutCommand)
      }
      normalizedSourceLocation = sourceLocation

    case .bareRepository:
      let sourcePath = try localRepositoryPath(sourceLocation: sourceLocation, fileManager: fileManager)
      try await gitRunner.run(
        worktreeAddCommand(checkout, sourcePath: sourcePath, destinationPath: destinationPath)
      )
      ledger.createdURLs.append(destinationURL)
      ledger.cleanupCommands.append(
        worktreeRemoveCommand(sourcePath: sourcePath, destinationPath: destinationPath)
      )
      normalizedSourceLocation = sourcePath
    }

    let entryBranchName: String?
    let entryBaseRef: String?
    switch checkout {
    case .link:
      entryBranchName = nil
      entryBaseRef = nil
    case .createBranch(let branchName, let baseRef):
      entryBranchName = branchName
      entryBaseRef = baseRef
    case .useExistingRef(let ref):
      entryBranchName = nil
      entryBaseRef = ref
    }

    return RepositoryEntry(
      id: repository.id.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? workspacePath,
      name: name,
      path: workspacePath,
      sourceKind: repository.sourceKind,
      sourceLocation: normalizedSourceLocation,
      branchName: entryBranchName,
      baseRef: entryBaseRef
    )
  }

  private static func validatedCheckout(
    _ checkout: ProjectWorkspaceRepositoryCheckout,
    sourceKind: ProjectWorkspaceRepositorySourceKind,
    name: String
  ) throws -> ProjectWorkspaceRepositoryCheckout {
    switch checkout {
    case .link:
      guard sourceKind.supportsLinkCheckout else {
        throw ProjectWorkspaceCreationError.linkCheckoutUnsupported(name)
      }
      return .link
    case .createBranch(let branchName, let baseRef):
      guard let trimmedBranch = branchName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
        throw ProjectWorkspaceCreationError.missingBranchName(name)
      }
      return .createBranch(
        branchName: trimmedBranch,
        baseRef: baseRef?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      )
    case .useExistingRef(let ref):
      guard let trimmedRef = ref.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
        throw ProjectWorkspaceCreationError.missingExistingRef(name)
      }
      return .useExistingRef(trimmedRef)
    }
  }

  private static func worktreeAddCommand(
    _ checkout: ProjectWorkspaceRepositoryCheckout,
    sourcePath: String,
    destinationPath: String
  ) -> ProjectWorkspaceGitCommand {
    var arguments = ["-C", sourcePath, "worktree", "add"]
    switch checkout {
    case .link:
      arguments += [destinationPath]
    case .createBranch(let branchName, let baseRef):
      arguments += ["-b", branchName, destinationPath]
      if let baseRef {
        arguments += ["--end-of-options", baseRef]
      }
    case .useExistingRef(let ref):
      arguments += [destinationPath, "--end-of-options", ref]
    }
    return ProjectWorkspaceGitCommand(arguments: arguments, currentDirectoryURL: nil)
  }

  private static func worktreeRemoveCommand(
    sourcePath: String,
    destinationPath: String
  ) -> ProjectWorkspaceGitCommand {
    ProjectWorkspaceGitCommand(
      arguments: ["-C", sourcePath, "worktree", "remove", "--force", destinationPath],
      currentDirectoryURL: nil
    )
  }

  private static func remoteCheckoutCommand(
    _ checkout: ProjectWorkspaceRepositoryCheckout,
    destinationPath: String
  ) -> ProjectWorkspaceGitCommand? {
    switch checkout {
    case .link:
      return nil
    case .createBranch(let branchName, let baseRef):
      var arguments = ["-C", destinationPath, "checkout", "-B", branchName]
      if let baseRef {
        arguments += ["--end-of-options", baseRef]
      }
      return ProjectWorkspaceGitCommand(arguments: arguments, currentDirectoryURL: nil)
    case .useExistingRef(let ref):
      return ProjectWorkspaceGitCommand(
        arguments: ["-C", destinationPath, "checkout", "--end-of-options", remoteCloneExistingCheckoutRef(ref)],
        currentDirectoryURL: nil
      )
    }
  }

  private static func remoteCloneExistingCheckoutRef(_ baseRef: String) -> String {
    let prefix = "origin/"
    guard baseRef.hasPrefix(prefix), baseRef.count > prefix.count else {
      return baseRef
    }
    return String(baseRef.dropFirst(prefix.count))
  }

  private static func localRepositoryPath(
    sourceLocation: String,
    fileManager: FileManager
  ) throws -> String {
    let repositoryPath = normalizedPath(URL(fileURLWithPath: sourceLocation), resolvingSymlinks: true)
    var repositoryIsDirectory = ObjCBool(false)
    guard fileManager.fileExists(atPath: repositoryPath, isDirectory: &repositoryIsDirectory),
      repositoryIsDirectory.boolValue
    else {
      throw ProjectWorkspaceCreationError.repositoryDoesNotExist(repositoryPath)
    }
    return repositoryPath
  }

  private static func uniqueRepositoryPath(
    for repository: ProjectWorkspaceRepositoryPlan,
    displayName: String,
    occupiedNames: inout Set<String>
  ) -> String {
    var baseName = sanitizedWorkspaceComponent(repository.path ?? "")
    if baseName.isEmpty {
      baseName = sanitizedWorkspaceComponent(displayName)
    }
    if baseName.isEmpty {
      baseName = "repository"
    }

    var candidate = baseName
    var suffix = 2
    while occupiedNames.contains(candidate.lowercased()) {
      candidate = "\(baseName)-\(suffix)"
      suffix += 1
    }
    occupiedNames.insert(candidate.lowercased())
    return candidate
  }

  private static func repositoryDisplayName(_ repository: ProjectWorkspaceRepositoryPlan) -> String {
    let trimmedName = repository.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedName.isEmpty {
      return trimmedName
    }
    switch repository.sourceKind {
    case .existingPath, .localRepository, .bareRepository:
      if let localSourceURL = repository.localSourceURL {
        return Repository.name(for: localSourceURL)
      }
    case .remote:
      let name = GitRemoteNaming.repositoryName(fromRemoteURL: repository.sourceLocation)
      if !name.isEmpty {
        return name
      }
    }
    return ""
  }

  private static func sanitizedWorkspaceComponent(_ value: String) -> String {
    var result = ""
    for scalar in value.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
      if CharacterSet.whitespacesAndNewlines.contains(scalar)
        || CharacterSet(charactersIn: "/:").contains(scalar)
      {
        result.append("-")
      } else {
        result.unicodeScalars.append(scalar)
      }
    }
    while result.contains("--") {
      result = result.replacing("--", with: "-")
    }
    result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    if result == "." || result == ".." {
      return ""
    }
    return result
  }

  private static func normalizedPath(_ url: URL, resolvingSymlinks: Bool) -> String {
    var path = PathPolicy.normalizeURL(url, resolvingSymlinks: resolvingSymlinks).path(percentEncoded: false)
    while path.count > 1, path.hasSuffix("/") {
      path.removeLast()
    }
    return path
  }
}

extension String {
  nonisolated fileprivate var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
