import ComposableArchitecture
import Foundation

@MainActor
final class PullRequestRefreshCoordinator {
  nonisolated struct Request: Equatable, Sendable {
    let repositoryID: Repository.ID
    let repositoryRootURL: URL
    let host: String
    let owner: String
    let repo: String
    let accountOverride: GithubAccountOverride?
    let branches: [String]
    let worktreeIDs: [Worktree.ID]
  }

  nonisolated enum Outcome: Sendable, Equatable {
    case refreshed(
      repositoryID: Repository.ID,
      repositoryRootURL: URL,
      worktreeIDs: [Worktree.ID],
      prsByBranch: [String: GithubPullRequest]
    )
    case failed(
      repositoryID: Repository.ID,
      worktreeIDs: [Worktree.ID],
      message: String
    )
  }

  private let githubCLI: GithubCLIClient
  private let clock: any Clock<Duration>
  private let debounceWindow: Duration
  private let softTimeout: Duration
  private let resultHandler: @MainActor (Outcome) -> Void

  private struct BatchKey: Hashable, Sendable {
    let host: String
    let accountOverride: GithubAccountOverride?
  }

  private var pendingByHost: [BatchKey: [Repository.ID: Request]] = [:]
  private var flushTaskByHost: [BatchKey: Task<Void, Never>] = [:]
  private var inflightHosts: Set<BatchKey> = []
  private var queuedByHost: [BatchKey: [Repository.ID: Request]] = [:]

  init(
    githubCLI: GithubCLIClient,
    clock: any Clock<Duration>,
    debounceWindow: Duration = .milliseconds(250),
    softTimeout: Duration = .seconds(12),
    resultHandler: @MainActor @escaping (Outcome) -> Void
  ) {
    self.githubCLI = githubCLI
    self.clock = clock
    self.debounceWindow = debounceWindow
    self.softTimeout = softTimeout
    self.resultHandler = resultHandler
  }

  func enqueue(_ request: Request) {
    // Trim and drop whitespace-only entries so "feat" and "feat " do not get treated as
    // distinct branches downstream and don't leak padding into the GraphQL headRefName.
    let cleanedBranches = request.branches.compactMap { branch -> String? in
      let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    guard !cleanedBranches.isEmpty else {
      return
    }
    let normalized = Request(
      repositoryID: request.repositoryID,
      repositoryRootURL: request.repositoryRootURL,
      host: request.host,
      owner: request.owner,
      repo: request.repo,
      accountOverride: request.accountOverride,
      branches: cleanedBranches,
      worktreeIDs: request.worktreeIDs
    )

    let key = BatchKey(host: normalized.host, accountOverride: normalized.accountOverride)
    if inflightHosts.contains(key) {
      mergeRequest(normalized, into: &queuedByHost)
      return
    }

    mergeRequest(normalized, into: &pendingByHost)
    rescheduleDebounce(forKey: key)
  }

  func cancelHost(_ host: String) {
    for key in flushTaskByHost.keys where key.host == host {
      flushTaskByHost.removeValue(forKey: key)?.cancel()
    }
    pendingByHost = pendingByHost.filter { $0.key.host != host }
    queuedByHost = queuedByHost.filter { $0.key.host != host }
    inflightHosts = inflightHosts.filter { $0.host != host }
  }

  func reset() {
    for (_, task) in flushTaskByHost {
      task.cancel()
    }
    flushTaskByHost.removeAll()
    pendingByHost.removeAll()
    queuedByHost.removeAll()
    inflightHosts.removeAll()
  }

  private func mergeRequest(
    _ request: Request,
    into bucket: inout [BatchKey: [Repository.ID: Request]]
  ) {
    let key = BatchKey(host: request.host, accountOverride: request.accountOverride)
    var hostBucket = bucket[key] ?? [:]
    if let existing = hostBucket[request.repositoryID] {
      var seen = Set<String>(existing.branches)
      var combined = existing.branches
      for branch in request.branches where seen.insert(branch).inserted {
        combined.append(branch)
      }
      var workseen = Set<Worktree.ID>(existing.worktreeIDs)
      var workCombined = existing.worktreeIDs
      for worktreeID in request.worktreeIDs where workseen.insert(worktreeID).inserted {
        workCombined.append(worktreeID)
      }
      hostBucket[request.repositoryID] = Request(
        repositoryID: request.repositoryID,
        repositoryRootURL: request.repositoryRootURL,
        host: request.host,
        owner: request.owner,
        repo: request.repo,
        accountOverride: request.accountOverride,
        branches: combined,
        worktreeIDs: workCombined
      )
    } else {
      hostBucket[request.repositoryID] = request
    }
    bucket[key] = hostBucket
  }

  private func rescheduleDebounce(forKey key: BatchKey) {
    flushTaskByHost.removeValue(forKey: key)?.cancel()
    let task = Task { [weak self, debounceWindow, clock] in
      do {
        try await clock.sleep(for: debounceWindow)
      } catch {
        return
      }
      await self?.flush(key: key)
    }
    flushTaskByHost[key] = task
  }

  private func flush(key: BatchKey) async {
    flushTaskByHost.removeValue(forKey: key)
    guard let bucket = pendingByHost.removeValue(forKey: key), !bucket.isEmpty else {
      return
    }
    inflightHosts.insert(key)
    let requests = Array(bucket.values)
    await processBatch(key: key, requests: requests)
    inflightHosts.remove(key)
    if let queued = queuedByHost.removeValue(forKey: key), !queued.isEmpty {
      pendingByHost[key, default: [:]].merge(queued) { _, new in new }
      await flush(key: key)
    }
  }

  private func processBatch(key: BatchKey, requests: [Request]) async {
    let groupsByKey = groupRequestsByRepo(requests)
    let crossRepoRequests = groupsByKey.values.map { group in
      CrossRepoPullRequestRequest(
        owner: group.key.owner,
        repo: group.key.repo,
        branches: group.branches
      )
    }
    do {
      let result = try await runBatchWithTimeout(
        host: key.host,
        requests: crossRepoRequests,
        accountOverride: key.accountOverride
      )
      for (key, prsByBranch) in result.successByRepo {
        guard let group = groupsByKey[key] else {
          continue
        }
        for request in group.requests {
          resultHandler(
            .refreshed(
              repositoryID: request.repositoryID,
              repositoryRootURL: request.repositoryRootURL,
              worktreeIDs: request.worktreeIDs,
              prsByBranch: prsByBranch.filter { request.branches.contains($0.key) }
            )
          )
        }
      }
      let failedRequests = result.failedRepos.keys.flatMap { key in
        groupsByKey[key]?.requests ?? []
      }
      if !failedRequests.isEmpty {
        await fanOutFallback(failedRequests)
      }
    } catch {
      await fanOutFallback(requests)
    }
  }

  private func fanOutFallback(_ requests: [Request]) async {
    let groups = Array(groupRequestsByRepo(requests).values)
    // Run per-repo fallback requests concurrently; serial awaits here would multiply
    // a slow recovery path by the number of repos in the batch.
    await withTaskGroup(of: Void.self) { group in
      for requestGroup in groups {
        group.addTask { [weak self] in
          await self?.fallbackPerRepo(requestGroup)
        }
      }
    }
  }

  private func runBatchWithTimeout(
    host: String,
    requests: [CrossRepoPullRequestRequest],
    accountOverride: GithubAccountOverride?
  ) async throws -> CrossRepoPullRequestResult {
    try await withThrowingTaskGroup(of: BatchTimeoutOutcome.self) { group in
      let githubCLI = self.githubCLI
      let softTimeout = self.softTimeout
      let clock = self.clock
      group.addTask {
        let value = try await githubCLI.batchPullRequestsAcrossRepositories(host, requests, accountOverride)
        return .completed(value)
      }
      group.addTask {
        try await clock.sleep(for: softTimeout)
        return .timedOut
      }
      defer { group.cancelAll() }
      while let outcome = try await group.next() {
        switch outcome {
        case .completed(let value):
          return value
        case .timedOut:
          throw PullRequestRefreshCoordinatorError.softTimeout
        }
      }
      throw PullRequestRefreshCoordinatorError.softTimeout
    }
  }

  private func fallbackPerRepo(_ group: RepoRequestGroup) async {
    do {
      let prs = try await githubCLI.batchPullRequests(
        group.requests[0].host,
        group.key.owner,
        group.key.repo,
        group.branches,
        group.requests[0].accountOverride
      )
      for request in group.requests {
        resultHandler(
          .refreshed(
            repositoryID: request.repositoryID,
            repositoryRootURL: request.repositoryRootURL,
            worktreeIDs: request.worktreeIDs,
            prsByBranch: prs.filter { request.branches.contains($0.key) }
          )
        )
      }
    } catch {
      for request in group.requests {
        resultHandler(
          .failed(
            repositoryID: request.repositoryID,
            worktreeIDs: request.worktreeIDs,
            message: String(describing: error)
          )
        )
      }
    }
  }

  private func groupRequestsByRepo(_ requests: [Request]) -> [RepoKey: RepoRequestGroup] {
    var groupsByKey: [RepoKey: RepoRequestGroup] = [:]
    for request in requests {
      let key = RepoKey(owner: request.owner, repo: request.repo)
      groupsByKey[key, default: RepoRequestGroup(key: key)].append(request)
    }
    return groupsByKey
  }

  private struct RepoRequestGroup: Sendable {
    let key: RepoKey
    private(set) var requests: [Request] = []
    private(set) var branches: [String] = []
    private var seenBranches: Set<String> = []

    init(key: RepoKey) {
      self.key = key
    }

    mutating func append(_ request: Request) {
      requests.append(request)
      for branch in request.branches where seenBranches.insert(branch).inserted {
        branches.append(branch)
      }
    }
  }

  private enum BatchTimeoutOutcome: Sendable {
    case completed(CrossRepoPullRequestResult)
    case timedOut
  }
}

enum PullRequestRefreshCoordinatorError: Error, Equatable {
  case softTimeout
}

nonisolated struct PullRequestRefreshCoordinatorClient: Sendable {
  var enqueue: @Sendable (PullRequestRefreshCoordinator.Request) -> Void
  var cancelHost: @Sendable (String) -> Void
  var reset: @Sendable () -> Void

  nonisolated static let unimplemented = PullRequestRefreshCoordinatorClient(
    enqueue: { _ in },
    cancelHost: { _ in },
    reset: {}
  )
}

extension PullRequestRefreshCoordinatorClient: DependencyKey {
  nonisolated static let liveValue = unimplemented
  nonisolated static let testValue = unimplemented
}

extension DependencyValues {
  var pullRequestRefreshCoordinator: PullRequestRefreshCoordinatorClient {
    get { self[PullRequestRefreshCoordinatorClient.self] }
    set { self[PullRequestRefreshCoordinatorClient.self] = newValue }
  }
}
