import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import supacode

@MainActor
struct BatchedPullRequestRefreshReducerTests {
  @Test func batchedFlagOffStillRunsLegacyBatchPullRequests() async {
    let context = makeContext()
    let store = TestStore(initialState: context.state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.remoteInfo = { _ in context.remoteInfo }
      $0.githubCLI.resolveRemoteInfo = { _ in context.remoteInfo }
      $0.githubCLI.batchPullRequests = { _, _, _, _ in [:] }
      $0.pullRequestRefreshCoordinator = .unimplemented
    }
    // Flag default false → exercises legacy code path; assert no coordinator call by relying on
    // the unimplemented default coordinator which does nothing.

    await store.send(
      .worktreeInfoEvent(
        .repositoryPullRequestRefresh(
          repositoryRootURL: context.repoRootURL,
          worktreeIDs: context.worktreeIDs
        )
      )
    )
    await store.receive(\.githubIntegration.repositoryPullRequestRefreshRequested) {
      $0.inFlightPullRequestRefreshRepositoryIDs = [context.repository.id]
    }
    await store.receive(\.githubIntegration.repositoryPullRequestsLoaded)
    await store.receive(\.githubIntegration.repositoryPullRequestRefreshCompleted) {
      $0.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.finish()
  }

  @Test func batchedFlagOnDispatchesViaCoordinatorWhenRemoteInfoCached() async {
    let context = makeContext()
    let enqueued = LockIsolated<[PullRequestRefreshCoordinator.Request]>([])
    var initialState = context.state
    initialState.$batchedPullRequestRefreshEnabled.withLock { $0 = true }
    initialState.remoteInfoByRepositoryID[context.repository.id] = context.remoteInfo

    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.githubCLI.resolveRemoteInfo = { _ in
        Issue.record("Should not resolve when cache hit")
        return nil
      }
      $0.githubCLI.batchPullRequests = { _, _, _, _ in
        Issue.record("Legacy batchPullRequests should not run on coordinator path")
        return [:]
      }
      $0.pullRequestRefreshCoordinator = PullRequestRefreshCoordinatorClient(
        enqueue: { request in
          enqueued.withValue { $0.append(request) }
        },
        cancelHost: { _ in },
        reset: {}
      )
    }

    await store.send(
      .worktreeInfoEvent(
        .repositoryPullRequestRefresh(
          repositoryRootURL: context.repoRootURL,
          worktreeIDs: context.worktreeIDs
        )
      )
    )
    await store.receive(\.githubIntegration.repositoryPullRequestRefreshRequested) {
      $0.inFlightPullRequestRefreshRepositoryIDs = [context.repository.id]
    }
    await store.finish()

    let snapshot = enqueued.value
    #expect(snapshot.count == 1)
    let request = try? #require(snapshot.first)
    #expect(request?.host == "github.com")
    #expect(request?.owner == "khoi")
    #expect(request?.repo == "alpha")
    #expect(request?.branches == ["main", "feature"])
  }

  @Test func batchedFlagOnResolvesAndCachesRemoteInfoOnFirstRun() async {
    let context = makeContext()
    let enqueued = LockIsolated<[PullRequestRefreshCoordinator.Request]>([])
    var initialState = context.state
    initialState.$batchedPullRequestRefreshEnabled.withLock { $0 = true }

    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.githubCLI.resolveRemoteInfo = { _ in context.remoteInfo }
      $0.gitClient.remoteInfo = { _ in
        Issue.record("git remoteInfo should not be used when gh resolve succeeds")
        return nil
      }
      $0.pullRequestRefreshCoordinator = PullRequestRefreshCoordinatorClient(
        enqueue: { request in
          enqueued.withValue { $0.append(request) }
        },
        cancelHost: { _ in },
        reset: {}
      )
    }

    await store.send(
      .worktreeInfoEvent(
        .repositoryPullRequestRefresh(
          repositoryRootURL: context.repoRootURL,
          worktreeIDs: context.worktreeIDs
        )
      )
    )
    await store.receive(\.githubIntegration.repositoryPullRequestRefreshRequested) {
      $0.inFlightPullRequestRefreshRepositoryIDs = [context.repository.id]
    }
    await store.receive(\.githubIntegration.cacheRemoteInfo) {
      $0.remoteInfoByRepositoryID[context.repository.id] = context.remoteInfo
    }
    await store.finish()

    #expect(enqueued.value.count == 1)
  }

  @Test func coordinatorOutcomeRefreshedTranslatesToLoadedAndCompleted() async {
    let context = makeContext()
    var initialState = context.state
    initialState.inFlightPullRequestRefreshRepositoryIDs = [context.repository.id]

    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.pullRequestRefreshCoordinator = .unimplemented
    }

    let pullRequest = makePullRequestFixture()
    let outcome = PullRequestRefreshCoordinator.Outcome.refreshed(
      repositoryID: context.repository.id,
      repositoryRootURL: context.repoRootURL,
      worktreeIDs: context.worktreeIDs,
      prsByBranch: ["feature": pullRequest]
    )

    await store.send(.githubIntegration(.pullRequestRefreshBatchOutcome(outcome)))
    await store.receive(\.githubIntegration.repositoryPullRequestsLoaded) {
      var entry = WorktreeInfoEntry()
      entry.pullRequest = pullRequest
      $0.worktreeInfoByID[context.featureWorktree.id] = entry
    }
    await store.receive(\.githubIntegration.repositoryPullRequestRefreshCompleted) {
      $0.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.finish()
  }

  @Test func coordinatorOutcomeFailedClearsInFlight() async {
    let context = makeContext()
    var initialState = context.state
    initialState.inFlightPullRequestRefreshRepositoryIDs = [context.repository.id]

    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.pullRequestRefreshCoordinator = .unimplemented
    }

    let outcome = PullRequestRefreshCoordinator.Outcome.failed(
      repositoryID: context.repository.id,
      worktreeIDs: context.worktreeIDs,
      message: "boom"
    )

    await store.send(.githubIntegration(.pullRequestRefreshBatchOutcome(outcome)))
    await store.receive(\.githubIntegration.repositoryPullRequestRefreshCompleted) {
      $0.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.finish()
  }

  @Test func cacheRemoteInfoStoresMappingInState() async {
    let context = makeContext()
    let store = TestStore(initialState: context.state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.pullRequestRefreshCoordinator = .unimplemented
    }

    await store.send(
      .githubIntegration(
        .cacheRemoteInfo(repositoryID: context.repository.id, remoteInfo: context.remoteInfo)
      )
    ) {
      $0.remoteInfoByRepositoryID[context.repository.id] = context.remoteInfo
    }
    await store.finish()
  }
}

// MARK: - Fixtures

@MainActor
private func makeContext() -> RefreshTestContext {
  let repoRoot = "/tmp/coord-repo"
  let mainWorktree = Worktree(
    id: repoRoot,
    name: "main",
    detail: "detail",
    workingDirectory: URL(fileURLWithPath: repoRoot),
    repositoryRootURL: URL(fileURLWithPath: repoRoot)
  )
  let featureWorktree = Worktree(
    id: "\(repoRoot)/feature",
    name: "feature",
    detail: "detail",
    workingDirectory: URL(fileURLWithPath: "\(repoRoot)/feature"),
    repositoryRootURL: URL(fileURLWithPath: repoRoot)
  )
  let repository = Repository(
    id: repoRoot,
    rootURL: URL(fileURLWithPath: repoRoot),
    name: "alpha",
    worktrees: IdentifiedArrayOf(uniqueElements: [mainWorktree, featureWorktree])
  )
  var state = RepositoriesFeature.State()
  state.repositories = [repository]
  state.repositoryRoots = [repository.rootURL]
  state.githubIntegrationAvailability = .available
  return RefreshTestContext(
    repoRoot: repoRoot,
    repository: repository,
    mainWorktree: mainWorktree,
    featureWorktree: featureWorktree,
    remoteInfo: GithubRemoteInfo(host: "github.com", owner: "khoi", repo: "alpha"),
    state: state
  )
}

@MainActor
private struct RefreshTestContext {
  let repoRoot: String
  let repository: Repository
  let mainWorktree: Worktree
  let featureWorktree: Worktree
  let remoteInfo: GithubRemoteInfo
  let state: RepositoriesFeature.State

  var repoRootURL: URL { URL(fileURLWithPath: repoRoot) }
  var worktreeIDs: [Worktree.ID] { [mainWorktree.id, featureWorktree.id] }
}

nonisolated private func makePullRequestFixture() -> GithubPullRequest {
  GithubPullRequest(
    number: 7,
    title: "Coord PR",
    state: "OPEN",
    additions: 0,
    deletions: 0,
    isDraft: false,
    reviewDecision: nil,
    mergeable: nil,
    mergeStateStatus: nil,
    updatedAt: nil,
    url: "https://example.com/coord-pr/7",
    headRefName: "feature",
    baseRefName: "main",
    commitsCount: 1,
    authorLogin: "khoi",
    statusCheckRollup: nil
  )
}
