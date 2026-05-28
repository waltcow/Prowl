import ComposableArchitecture
import Darwin
import Foundation

struct GithubAuthStatus: Equatable, Sendable {
  let username: String
  let host: String
}

private struct GithubAuthStatusResponse: Sendable {
  let hosts: [String: [GithubAuthAccount]]

  struct GithubAuthAccount: Sendable {
    let active: Bool
    let login: String
  }
}

extension GithubAuthStatusResponse: Decodable {
  private enum CodingKeys: String, CodingKey {
    case hosts
  }

  nonisolated init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.hosts = try container.decode([String: [GithubAuthAccount]].self, forKey: .hosts)
  }
}

extension GithubAuthStatusResponse.GithubAuthAccount: Decodable {
  private enum CodingKeys: String, CodingKey {
    case active
    case login
  }

  nonisolated init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.active = try container.decode(Bool.self, forKey: .active)
    self.login = try container.decode(String.self, forKey: .login)
  }
}

nonisolated struct RepoKey: Hashable, Sendable {
  let owner: String
  let repo: String
}

nonisolated struct CrossRepoPullRequestRequest: Sendable, Hashable {
  let owner: String
  let repo: String
  let branches: [String]

  var key: RepoKey {
    RepoKey(owner: owner, repo: repo)
  }
}

nonisolated struct CrossRepoPullRequestResult: Sendable {
  let successByRepo: [RepoKey: [String: GithubPullRequest]]
  let failedRepos: [RepoKey: GithubCLIError]

  init(
    successByRepo: [RepoKey: [String: GithubPullRequest]] = [:],
    failedRepos: [RepoKey: GithubCLIError] = [:]
  ) {
    self.successByRepo = successByRepo
    self.failedRepos = failedRepos
  }
}

struct GithubCLIClient: Sendable {
  var defaultBranch: @Sendable (URL) async throws -> String
  var resolveRemoteInfo: @Sendable (URL) async -> GithubRemoteInfo?
  var latestRun: @Sendable (URL, String) async throws -> GithubWorkflowRun?
  var batchPullRequests: @Sendable (String, String, String, [String]) async throws -> [String: GithubPullRequest]
  var batchPullRequestsAcrossRepositories:
    @Sendable (String, [CrossRepoPullRequestRequest]) async throws -> CrossRepoPullRequestResult
  var mergePullRequest: @Sendable (URL, GithubRemoteInfo, Int, PullRequestMergeStrategy) async throws -> Void
  var closePullRequest: @Sendable (URL, GithubRemoteInfo, Int) async throws -> Void
  var markPullRequestReady: @Sendable (URL, GithubRemoteInfo, Int) async throws -> Void
  var rerunFailedJobs: @Sendable (URL, Int) async throws -> Void
  var failedRunLogs: @Sendable (URL, Int) async throws -> String
  var runLogs: @Sendable (URL, Int) async throws -> String
  var isAvailable: @Sendable () async -> Bool
  var authStatus: @Sendable () async throws -> GithubAuthStatus?
}

extension GithubCLIClient: DependencyKey {
  static let liveValue = live()

  static func live(shell: ShellClient = .liveValue) -> GithubCLIClient {
    let resolver = GithubCLIExecutableResolver()
    return GithubCLIClient(
      defaultBranch: defaultBranchFetcher(shell: shell, resolver: resolver),
      resolveRemoteInfo: resolveRemoteInfoFetcher(shell: shell, resolver: resolver),
      latestRun: latestRunFetcher(shell: shell, resolver: resolver),
      batchPullRequests: batchPullRequestsFetcher(shell: shell, resolver: resolver),
      batchPullRequestsAcrossRepositories: batchPullRequestsAcrossRepositoriesFetcher(shell: shell, resolver: resolver),
      mergePullRequest: mergePullRequestFetcher(shell: shell, resolver: resolver),
      closePullRequest: closePullRequestFetcher(shell: shell, resolver: resolver),
      markPullRequestReady: markPullRequestReadyFetcher(shell: shell, resolver: resolver),
      rerunFailedJobs: rerunFailedJobsFetcher(shell: shell, resolver: resolver),
      failedRunLogs: failedRunLogsFetcher(shell: shell, resolver: resolver),
      runLogs: runLogsFetcher(shell: shell, resolver: resolver),
      isAvailable: isAvailableFetcher(shell: shell, resolver: resolver),
      authStatus: authStatusFetcher(shell: shell, resolver: resolver)
    )
  }

  static let testValue = GithubCLIClient(
    defaultBranch: { _ in "main" },
    resolveRemoteInfo: { _ in nil },
    latestRun: { _, _ in nil },
    batchPullRequests: { _, _, _, _ in [:] },
    batchPullRequestsAcrossRepositories: { _, _ in CrossRepoPullRequestResult() },
    mergePullRequest: { _, _, _, _ in },
    closePullRequest: { _, _, _ in },
    markPullRequestReady: { _, _, _ in },
    rerunFailedJobs: { _, _ in },
    failedRunLogs: { _, _ in "" },
    runLogs: { _, _ in "" },
    isAvailable: { true },
    authStatus: { GithubAuthStatus(username: "testuser", host: "github.com") }
  )
}

extension DependencyValues {
  var githubCLI: GithubCLIClient {
    get { self[GithubCLIClient.self] }
    set { self[GithubCLIClient.self] = newValue }
  }
}

private struct GithubPullRequestsRequest: Sendable {
  let host: String
  let owner: String
  let repo: String
}

nonisolated private struct GithubRepoViewRemoteInfoResponse: Decodable, Sendable {
  let owner: Owner
  let name: String
  let url: String

  nonisolated var remoteInfo: GithubRemoteInfo? {
    guard let host = URL(string: url)?.host else {
      return nil
    }
    return GithubRemoteInfo(host: host, owner: owner.login, repo: name)
  }

  nonisolated struct Owner: Decodable, Sendable {
    let login: String
  }
}

private actor GithubCLIExecutableResolver {
  private var cachedExecutableURL: URL?
  private var inFlightResolution: Task<URL, Error>?

  func executableURL(shell: ShellClient) async throws -> URL {
    if let cachedExecutableURL {
      return cachedExecutableURL
    }
    if let inFlightResolution {
      return try await inFlightResolution.value
    }
    let resolutionTask = Task {
      try await resolveExecutableURL(shell: shell)
    }
    inFlightResolution = resolutionTask
    do {
      let executableURL = try await resolutionTask.value
      cachedExecutableURL = executableURL
      inFlightResolution = nil
      return executableURL
    } catch {
      inFlightResolution = nil
      throw error
    }
  }

  func invalidate() {
    cachedExecutableURL = nil
    inFlightResolution?.cancel()
    inFlightResolution = nil
  }

  private func resolveExecutableURL(shell: ShellClient) async throws -> URL {
    if let executableURL = await locateExecutableURL(
      shell: shell,
      useLoginShell: false
    ) {
      return executableURL
    }
    if let executableURL = await locateExecutableURL(
      shell: shell,
      useLoginShell: true
    ) {
      return executableURL
    }
    throw GithubCLIError.unavailable
  }

  private func locateExecutableURL(
    shell: ShellClient,
    useLoginShell: Bool
  ) async -> URL? {
    let whichURL = URL(fileURLWithPath: "/usr/bin/which")
    do {
      let output: String
      if useLoginShell {
        output = try await shell.runLogin(
          whichURL,
          ["gh"],
          nil,
          log: false
        ).stdout
      } else {
        output = try await shell.run(whichURL, ["gh"], nil).stdout
      }
      let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        return nil
      }
      return URL(fileURLWithPath: trimmed)
    } catch {
      return nil
    }
  }
}

nonisolated private func defaultBranchFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable (URL) async throws -> String {
  { repoRoot in
    let output = try await runGh(
      shell: shell,
      resolver: resolver,
      arguments: ["repo", "view", "--json", "defaultBranchRef"],
      repoRoot: repoRoot
    )
    let data = Data(output.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let response = try decoder.decode(GithubRepoViewResponse.self, from: data)
    return response.defaultBranchRef.name
  }
}

nonisolated private func resolveRemoteInfoFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable (URL) async -> GithubRemoteInfo? {
  { repoRoot in
    do {
      let output = try await runGh(
        shell: shell,
        resolver: resolver,
        arguments: ["repo", "view", "--json", "owner,name,url"],
        repoRoot: repoRoot
      )
      let data = Data(output.utf8)
      let response = try JSONDecoder().decode(GithubRepoViewRemoteInfoResponse.self, from: data)
      return response.remoteInfo
    } catch {
      return nil
    }
  }
}

nonisolated private func latestRunFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable (URL, String) async throws -> GithubWorkflowRun? {
  { repoRoot, branch in
    let output = try await runGh(
      shell: shell,
      resolver: resolver,
      arguments: [
        "run",
        "list",
        "--branch",
        branch,
        "--limit",
        "1",
        "--json",
        "databaseId,workflowName,name,displayTitle,status,conclusion,createdAt,updatedAt",
      ],
      repoRoot: repoRoot
    )
    if output.isEmpty {
      return nil
    }
    let data = Data(output.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let runs = try decoder.decode([GithubWorkflowRun].self, from: data)
    return runs.first
  }
}

nonisolated private func batchPullRequestsFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable (String, String, String, [String]) async throws -> [String: GithubPullRequest] {
  { host, owner, repo, branches in
    let dedupedBranches = deduplicatedBranches(branches)
    guard !dedupedBranches.isEmpty else {
      return [:]
    }
    let request = GithubPullRequestsRequest(host: host, owner: owner, repo: repo)
    let chunks = makeBranchChunks(
      dedupedBranches,
      chunkSize: batchPullRequestsChunkSize
    )
    let chunkResults = try await loadPullRequestChunks(
      shell: shell,
      resolver: resolver,
      request: request,
      chunks: chunks
    )
    return mergePullRequestChunkResults(
      chunkResults,
      chunkCount: chunks.count
    )
  }
}

nonisolated private let crossRepoBatchAliasLimit = 15
nonisolated private let crossRepoBatchMaxConcurrentRequests = 3
nonisolated private let crossRepoBatchLogger = SupaLogger("BPR")

nonisolated private struct CrossRepoChunkOutcome: Sendable {
  let successByRepo: [RepoKey: [String: GithubPullRequest]]
  let failedRepos: [RepoKey: GithubCLIError]
}

nonisolated private func batchPullRequestsAcrossRepositoriesFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable (String, [CrossRepoPullRequestRequest]) async throws -> CrossRepoPullRequestResult {
  { host, requests in
    let cleaned = sanitizeCrossRepoRequests(requests)
    guard !cleaned.isEmpty else {
      return CrossRepoPullRequestResult()
    }
    let chunks = makeCrossRepoChunks(cleaned, chunkSize: crossRepoBatchAliasLimit)
    // [BPR] remove after manual verification
    crossRepoBatchLogger.debug(
      "batch start host=\(host) repos=\(cleaned.count) chunks=\(chunks.count)"
    )
    let outcomes = try await loadCrossRepoChunks(
      shell: shell,
      resolver: resolver,
      host: host,
      chunks: chunks
    )
    return mergeCrossRepoChunkResults(outcomes)
  }
}

nonisolated private func sanitizeCrossRepoRequests(
  _ requests: [CrossRepoPullRequestRequest]
) -> [CrossRepoPullRequestRequest] {
  var sanitized: [CrossRepoPullRequestRequest] = []
  for request in requests {
    var seen = Set<String>()
    let branches = request.branches.filter { value in
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return !trimmed.isEmpty && seen.insert(value).inserted
    }
    guard !branches.isEmpty else {
      continue
    }
    sanitized.append(
      CrossRepoPullRequestRequest(owner: request.owner, repo: request.repo, branches: branches)
    )
  }
  return sanitized
}

nonisolated private func makeCrossRepoChunks(
  _ requests: [CrossRepoPullRequestRequest],
  chunkSize: Int
) -> [[CrossRepoPullRequestRequest]] {
  guard !requests.isEmpty else {
    return []
  }
  var chunks: [[CrossRepoPullRequestRequest]] = []
  var index = 0
  while index < requests.count {
    let end = min(index + chunkSize, requests.count)
    chunks.append(Array(requests[index..<end]))
    index = end
  }
  return chunks
}

nonisolated private func loadCrossRepoChunks(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver,
  host: String,
  chunks: [[CrossRepoPullRequestRequest]]
) async throws -> [CrossRepoChunkOutcome] {
  try await withThrowingTaskGroup(of: (Int, CrossRepoChunkOutcome).self) { group in
    var nextChunkIndex = 0
    let initialCount = min(crossRepoBatchMaxConcurrentRequests, chunks.count)
    while nextChunkIndex < initialCount {
      let chunkIndex = nextChunkIndex
      let chunk = chunks[chunkIndex]
      group.addTask {
        let outcome = try await fetchCrossRepoChunk(
          shell: shell,
          resolver: resolver,
          host: host,
          chunk: chunk,
          chunkIndex: chunkIndex
        )
        return (chunkIndex, outcome)
      }
      nextChunkIndex += 1
    }
    var resultsByIndex: [Int: CrossRepoChunkOutcome] = [:]
    while let (chunkIndex, outcome) = try await group.next() {
      resultsByIndex[chunkIndex] = outcome
      if nextChunkIndex < chunks.count {
        let candidateIndex = nextChunkIndex
        let candidateChunk = chunks[candidateIndex]
        group.addTask {
          let outcome = try await fetchCrossRepoChunk(
            shell: shell,
            resolver: resolver,
            host: host,
            chunk: candidateChunk,
            chunkIndex: candidateIndex
          )
          return (candidateIndex, outcome)
        }
        nextChunkIndex += 1
      }
    }
    return (0..<chunks.count).compactMap { resultsByIndex[$0] }
  }
}

nonisolated private func mergeCrossRepoChunkResults(
  _ outcomes: [CrossRepoChunkOutcome]
) -> CrossRepoPullRequestResult {
  var success: [RepoKey: [String: GithubPullRequest]] = [:]
  var failed: [RepoKey: GithubCLIError] = [:]
  for outcome in outcomes {
    for (key, prs) in outcome.successByRepo {
      success[key] = prs
    }
    for (key, error) in outcome.failedRepos {
      failed[key] = error
    }
  }
  return CrossRepoPullRequestResult(successByRepo: success, failedRepos: failed)
}

nonisolated private func fetchCrossRepoChunk(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver,
  host: String,
  chunk: [CrossRepoPullRequestRequest],
  chunkIndex: Int
) async throws -> CrossRepoChunkOutcome {
  let plan = makeCrossRepoBatchQuery(requests: chunk)
  // [BPR] remove after manual verification
  crossRepoBatchLogger.debug(
    "chunk[\(chunkIndex)] dispatch repos=\(plan.repoAliases.count) host=\(host)"
  )
  let output = try await runGh(
    shell: shell,
    resolver: resolver,
    arguments: [
      "api",
      "graphql",
      "--hostname",
      host,
      "-f",
      "query=\(plan.query)",
    ],
    repoRoot: nil
  )
  guard !output.isEmpty else {
    var failed: [RepoKey: GithubCLIError] = [:]
    for key in plan.repoAliases.values {
      failed[key] = .commandFailed("Empty response from gh api graphql")
    }
    return CrossRepoChunkOutcome(successByRepo: [:], failedRepos: failed)
  }
  let data = Data(output.utf8)
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let response = try decoder.decode(CrossRepoPullRequestResponse.self, from: data)

  let failedAliases = response.failedAliases()
  var success: [RepoKey: [String: GithubPullRequest]] = [:]
  var failed: [RepoKey: GithubCLIError] = [:]
  for (alias, key) in plan.repoAliases {
    if failedAliases.contains(alias) {
      // [BPR] remove after manual verification
      crossRepoBatchLogger.debug("chunk[\(chunkIndex)] partial-error alias=\(alias) repo=\(key.owner)/\(key.repo)")
      failed[key] = .commandFailed("Partial GraphQL error for \(key.owner)/\(key.repo)")
      continue
    }
    guard let payload = response.repositories[alias] else {
      failed[key] = .commandFailed("Missing response payload for \(key.owner)/\(key.repo)")
      continue
    }
    let branchAliasMap = plan.branchAliasesByRepo[alias] ?? [:]
    let prs = rankCrossRepoPullRequests(
      pullRequestsByAlias: payload.pullRequestsByAlias,
      aliasMap: branchAliasMap,
      owner: key.owner,
      repo: key.repo
    )
    success[key] = prs
  }
  // [BPR] remove after manual verification
  crossRepoBatchLogger.debug(
    "chunk[\(chunkIndex)] done success=\(success.count) failed=\(failed.count)"
  )
  return CrossRepoChunkOutcome(successByRepo: success, failedRepos: failed)
}

nonisolated private struct CrossRepoBatchQueryPlan: Sendable {
  let query: String
  let repoAliases: [String: RepoKey]
  let branchAliasesByRepo: [String: [String: String]]
}

nonisolated private func makeCrossRepoBatchQuery(
  requests: [CrossRepoPullRequestRequest]
) -> CrossRepoBatchQueryPlan {
  var repoAliases: [String: RepoKey] = [:]
  var branchAliasesByRepo: [String: [String: String]] = [:]
  var repoBlocks: [String] = []
  let orderBy = "orderBy: {field: UPDATED_AT, direction: DESC}"
  for (repoIndex, request) in requests.enumerated() {
    let repoAlias = "r\(repoIndex)"
    repoAliases[repoAlias] = RepoKey(owner: request.owner, repo: request.repo)
    var branchAliasMap: [String: String] = [:]
    var selections: [String] = []
    for (branchIndex, branch) in request.branches.enumerated() {
      let branchAlias = "\(repoAlias)_b\(branchIndex)"
      branchAliasMap[branchAlias] = branch
      let escapedBranch = escapeGraphQLString(branch)
      let pullRequestsArgs =
        "first: 5, states: [OPEN, MERGED], headRefName: \"\(escapedBranch)\", \(orderBy)"
      let selection = """
          \(branchAlias): pullRequests(\(pullRequestsArgs)) {
            nodes {
              number
              title
              state
              additions
              deletions
              isDraft
              reviewDecision
              mergeable
              mergeStateStatus
              url
              updatedAt
              headRefName
              baseRefName
              commits {
                totalCount
              }
              author {
                login
              }
              headRepository {
                name
                owner { login }
              }
              statusCheckRollup {
                contexts(first: 100) {
                  nodes {
                    ... on CheckRun {
                      name
                      status
                      conclusion
                      startedAt
                      completedAt
                      detailsUrl
                    }
                    ... on StatusContext {
                      context
                      state
                      targetUrl
                      createdAt
                    }
                  }
                }
              }
            }
          }
        """
      selections.append(selection)
    }
    branchAliasesByRepo[repoAlias] = branchAliasMap
    let escapedOwner = escapeGraphQLString(request.owner)
    let escapedRepo = escapeGraphQLString(request.repo)
    let block = """
        \(repoAlias): repository(owner: \"\(escapedOwner)\", name: \"\(escapedRepo)\") {
      \(selections.joined(separator: "\n"))
        }
      """
    repoBlocks.append(block)
  }
  let query = """
    query {
    \(repoBlocks.joined(separator: "\n"))
    }
    """
  return CrossRepoBatchQueryPlan(
    query: query,
    repoAliases: repoAliases,
    branchAliasesByRepo: branchAliasesByRepo
  )
}

nonisolated private func rankCrossRepoPullRequests(
  pullRequestsByAlias: [String: GithubGraphQLPullRequestResponse.PullRequestConnection],
  aliasMap: [String: String],
  owner: String,
  repo: String
) -> [String: GithubPullRequest] {
  let normalizedOwner = owner.lowercased()
  let normalizedRepo = repo.lowercased()
  var results: [String: GithubPullRequest] = [:]
  for (alias, connection) in pullRequestsByAlias {
    guard let branch = aliasMap[alias] else {
      continue
    }
    let upstreamCandidates = connection.nodes.filter {
      $0.matches(owner: normalizedOwner, repo: normalizedRepo)
    }
    let candidates: [GithubGraphQLPullRequestResponse.PullRequestNode]
    if !upstreamCandidates.isEmpty {
      candidates = upstreamCandidates
    } else {
      let forkCandidates = connection.nodes.filter {
        $0.headRepository != nil && $0.doesNotTargetSameBranch(branch)
      }
      candidates =
        if !forkCandidates.isEmpty {
          forkCandidates
        } else {
          connection.nodes.filter {
            $0.headRepository == nil && $0.doesNotTargetSameBranch(branch)
          }
        }
    }
    if let node = candidates.max(by: { left, right in
      let leftRank = left.stateRank
      let rightRank = right.stateRank
      if leftRank != rightRank {
        return leftRank < rightRank
      }
      let leftDate = left.updatedAt ?? .distantPast
      let rightDate = right.updatedAt ?? .distantPast
      if leftDate != rightDate {
        return leftDate < rightDate
      }
      return left.number < right.number
    }) {
      results[branch] = node.pullRequest
    }
  }
  return results
}

nonisolated private func mergePullRequestFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable (URL, GithubRemoteInfo, Int, PullRequestMergeStrategy) async throws -> Void {
  { repoRoot, remoteInfo, pullRequestNumber, strategy in
    _ = try await runGh(
      shell: shell,
      resolver: resolver,
      arguments: [
        "pr",
        "merge",
        "\(pullRequestNumber)",
        "--\(strategy.ghArgument)",
      ] + repoArgument(remoteInfo),
      repoRoot: repoRoot
    )
  }
}

nonisolated private func closePullRequestFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable (URL, GithubRemoteInfo, Int) async throws -> Void {
  { repoRoot, remoteInfo, pullRequestNumber in
    _ = try await runGh(
      shell: shell,
      resolver: resolver,
      arguments: [
        "pr",
        "close",
        "\(pullRequestNumber)",
      ] + repoArgument(remoteInfo),
      repoRoot: repoRoot
    )
  }
}

nonisolated private func markPullRequestReadyFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable (URL, GithubRemoteInfo, Int) async throws -> Void {
  { repoRoot, remoteInfo, pullRequestNumber in
    _ = try await runGh(
      shell: shell,
      resolver: resolver,
      arguments: [
        "pr",
        "ready",
        "\(pullRequestNumber)",
      ] + repoArgument(remoteInfo),
      repoRoot: repoRoot
    )
  }
}

nonisolated private func repoArgument(_ remoteInfo: GithubRemoteInfo) -> [String] {
  ["--repo", "\(remoteInfo.host)/\(remoteInfo.owner)/\(remoteInfo.repo)"]
}

nonisolated private func rerunFailedJobsFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable (URL, Int) async throws -> Void {
  { repoRoot, runID in
    _ = try await runGh(
      shell: shell,
      resolver: resolver,
      arguments: [
        "run",
        "rerun",
        "\(runID)",
        "--failed",
      ],
      repoRoot: repoRoot
    )
  }
}

nonisolated private func failedRunLogsFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable (URL, Int) async throws -> String {
  { repoRoot, runID in
    try await runGh(
      shell: shell,
      resolver: resolver,
      arguments: [
        "run",
        "view",
        "\(runID)",
        "--log-failed",
      ],
      repoRoot: repoRoot
    )
  }
}

nonisolated private func runLogsFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable (URL, Int) async throws -> String {
  { repoRoot, runID in
    try await runGh(
      shell: shell,
      resolver: resolver,
      arguments: [
        "run",
        "view",
        "\(runID)",
        "--log",
      ],
      repoRoot: repoRoot
    )
  }
}

nonisolated private func isAvailableFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable () async -> Bool {
  {
    do {
      _ = try await runGh(
        shell: shell,
        resolver: resolver,
        arguments: ["--version"],
        repoRoot: nil
      )
      return true
    } catch {
      return false
    }
  }
}

nonisolated private func authStatusFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable () async throws -> GithubAuthStatus? {
  {
    let output = try await runGh(
      shell: shell,
      resolver: resolver,
      arguments: ["auth", "status", "--json", "hosts"],
      repoRoot: nil
    )
    let data = Data(output.utf8)
    let response = try decodeAuthStatusResponse(from: data)
    guard let (host, accounts) = response.hosts.first,
      let activeAccount = accounts.first(where: { $0.active })
    else {
      return nil
    }
    return GithubAuthStatus(username: activeAccount.login, host: host)
  }
}

nonisolated private func deduplicatedBranches(_ branches: [String]) -> [String] {
  var seen = Set<String>()
  return branches.filter { !$0.isEmpty && seen.insert($0).inserted }
}

nonisolated private let batchPullRequestsChunkSize = 25
nonisolated private let batchPullRequestsMaxConcurrentRequests = 3

nonisolated private func makeBranchChunks(
  _ branches: [String],
  chunkSize: Int
) -> [[String]] {
  guard !branches.isEmpty else {
    return []
  }

  var chunks: [[String]] = []
  var index = 0
  while index < branches.count {
    let end = min(index + chunkSize, branches.count)
    chunks.append(Array(branches[index..<end]))
    index = end
  }

  return chunks
}

nonisolated private func loadPullRequestChunks(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver,
  request: GithubPullRequestsRequest,
  chunks: [[String]]
) async throws -> [Int: [String: GithubPullRequest]] {
  try await withThrowingTaskGroup(
    of: (Int, [String: GithubPullRequest]).self
  ) { group in
    var nextChunkIndex = 0
    let initialCount = min(batchPullRequestsMaxConcurrentRequests, chunks.count)
    while nextChunkIndex < initialCount {
      let chunkIndex = nextChunkIndex
      let chunk = chunks[chunkIndex]
      group.addTask {
        try await fetchPullRequestsChunk(
          shell: shell,
          resolver: resolver,
          request: request,
          chunk: chunk,
          chunkIndex: chunkIndex
        )
      }
      nextChunkIndex += 1
    }

    var resultsByChunkIndex: [Int: [String: GithubPullRequest]] = [:]
    while let (chunkIndex, prsByBranch) = try await group.next() {
      resultsByChunkIndex[chunkIndex] = prsByBranch
      if nextChunkIndex < chunks.count {
        let candidateIndex = nextChunkIndex
        let candidateChunk = chunks[candidateIndex]
        group.addTask {
          try await fetchPullRequestsChunk(
            shell: shell,
            resolver: resolver,
            request: request,
            chunk: candidateChunk,
            chunkIndex: candidateIndex
          )
        }
        nextChunkIndex += 1
      }
    }

    return resultsByChunkIndex
  }
}

nonisolated private func mergePullRequestChunkResults(
  _ chunkResults: [Int: [String: GithubPullRequest]],
  chunkCount: Int
) -> [String: GithubPullRequest] {
  var results: [String: GithubPullRequest] = [:]
  for chunkIndex in 0..<chunkCount {
    guard let prsByBranch = chunkResults[chunkIndex] else {
      continue
    }
    results.merge(prsByBranch) { _, new in new }
  }
  return results
}

nonisolated private func fetchPullRequestsChunk(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver,
  request: GithubPullRequestsRequest,
  chunk: [String],
  chunkIndex: Int
) async throws -> (Int, [String: GithubPullRequest]) {
  let (query, aliasMap) = makeBatchPullRequestsQuery(branches: chunk)
  let output = try await runGh(
    shell: shell,
    resolver: resolver,
    arguments: [
      "api",
      "graphql",
      "--hostname",
      request.host,
      "-f",
      "query=\(query)",
      "-f",
      "owner=\(request.owner)",
      "-f",
      "repo=\(request.repo)",
    ],
    repoRoot: nil
  )
  guard !output.isEmpty else {
    return (chunkIndex, [:])
  }

  let data = Data(output.utf8)
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let response = try decoder.decode(GithubGraphQLPullRequestResponse.self, from: data)
  let prsByBranch = response.pullRequestsByBranch(
    aliasMap: aliasMap,
    owner: request.owner,
    repo: request.repo
  )
  return (chunkIndex, prsByBranch)
}

nonisolated private func makeBatchPullRequestsQuery(
  branches: [String]
) -> (query: String, aliasMap: [String: String]) {
  var aliasMap: [String: String] = [:]
  var selections: [String] = []
  for (index, branch) in branches.enumerated() {
    let alias = "branch\(index)"
    aliasMap[alias] = branch
    let escapedBranch = escapeGraphQLString(branch)
    let orderBy = "orderBy: {field: UPDATED_AT, direction: DESC}"
    let selection = """
      \(alias): pullRequests(first: 5, states: [OPEN, MERGED], headRefName: \"\(escapedBranch)\", \(orderBy)) {
        nodes {
          number
          title
          state
          additions
          deletions
          isDraft
          reviewDecision
          mergeable
          mergeStateStatus
          url
          updatedAt
          headRefName
          baseRefName
          commits {
            totalCount
          }
          author {
            login
          }
          headRepository {
            name
            owner { login }
          }
          statusCheckRollup {
            contexts(first: 100) {
              nodes {
                ... on CheckRun {
                  name
                  status
                  conclusion
                  startedAt
                  completedAt
                  detailsUrl
                }
                ... on StatusContext {
                  context
                  state
                  targetUrl
                  createdAt
                }
              }
            }
          }
        }
      }
      """
    selections.append(selection)
  }
  let selectionBlock = selections.joined(separator: "\n")
  let query = """
    query($owner: String!, $repo: String!) {
      repository(owner: $owner, name: $repo) {
    \(selectionBlock)
      }
    }
    """
  return (query, aliasMap)
}

nonisolated private func escapeGraphQLString(_ value: String) -> String {
  value
    .replacing("\\", with: "\\\\")
    .replacing("\"", with: "\\\"")
    .replacing("\n", with: "\\n")
    .replacing("\r", with: "\\r")
    .replacing("\t", with: "\\t")
}

nonisolated private func isOutdatedGitHubCLI(_ error: ShellClientError) -> Bool {
  let combined = "\(error.stdout)\n\(error.stderr)".lowercased()
  if combined.contains("unknown flag: --json") {
    return true
  }
  if combined.contains("unknown shorthand flag") && combined.contains("json") {
    return true
  }
  return false
}

nonisolated private func runGh(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver,
  arguments: [String],
  repoRoot: URL?
) async throws -> String {
  let command = (["gh"] + arguments).joined(separator: " ")
  do {
    let executableURL = try await resolver.executableURL(shell: shell)
    do {
      return try await shell.runLogin(executableURL, arguments, repoRoot, log: false).stdout
    } catch {
      guard shouldRetryGhExecution(after: error) else {
        throw error
      }
      await resolver.invalidate()
      let executableURL = try await resolver.executableURL(shell: shell)
      return try await shell.runLogin(executableURL, arguments, repoRoot, log: false).stdout
    }
  } catch let error as GithubCLIError {
    throw error
  } catch {
    if let shellError = error as? ShellClientError {
      if isOutdatedGitHubCLI(shellError) {
        throw GithubCLIError.outdated
      }
      let message = shellError.errorDescription ?? "Command failed: \(command)"
      throw GithubCLIError.commandFailed(message)
    }
    throw GithubCLIError.commandFailed(error.localizedDescription)
  }
}

nonisolated private func shouldRetryGhExecution(after error: Error) -> Bool {
  if let shellError = error as? ShellClientError {
    let combined = "\(shellError.stdout)\n\(shellError.stderr)".lowercased()
    if combined.contains("no such file or directory") || combined.contains("command not found") {
      return true
    }
    if shellError.exitCode == 127 {
      return true
    }
  }
  let nsError = error as NSError
  if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError {
    return true
  }
  if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT) {
    return true
  }
  return false
}

nonisolated private func decodeAuthStatusResponse(from data: Data) throws -> GithubAuthStatusResponse {
  try JSONDecoder().decode(GithubAuthStatusResponse.self, from: data)
}
