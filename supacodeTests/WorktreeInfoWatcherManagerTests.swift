import Clocks
import Foundation
import Testing

@testable import supacode

@MainActor
struct WorktreeInfoWatcherManagerTests {
  @Test func emitsLineChangesImmediatelyOnInitialWorktreeLoad() async throws {
    let tempWorktree = try makeTempWorktree()
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600)
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees([tempWorktree.worktree]))

    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: tempWorktree.worktree.id) == 1)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempWorktree.tempRoot)
  }

  @Test func worktreesAddedAfterInitialLoadRefreshLineChangesOnce() async throws {
    let clock = TestClock()
    let tempRepository = try makeTempRepository(worktreeNames: ["sparrow", "swift"])
    let firstWorktree = try #require(tempRepository.worktrees.first)
    let secondWorktree = try #require(tempRepository.worktrees.dropFirst().first)
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .milliseconds(80),
      unfocusedInterval: .milliseconds(80),
      lineChangePhaseOffset: { _, _ in .zero },
      pullRequestPhaseOffset: { _, _ in .zero },
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees([firstWorktree]))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: firstWorktree.id) == 1)

    manager.handleCommand(.setWorktrees([firstWorktree, secondWorktree]))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: secondWorktree.id) == 0)

    await clock.advance(by: .milliseconds(79))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: secondWorktree.id) == 0)

    await clock.advance(by: .milliseconds(1))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: secondWorktree.id) == 1)

    await clock.advance(by: .milliseconds(80))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: secondWorktree.id) == 1)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempRepository.tempRoot)
  }

  @Test func staggersDeferredLineChangesAcrossWorktrees() async throws {
    let clock = TestClock()
    let tempRepository = try makeTempRepository(worktreeNames: ["sparrow", "swift", "eagle"])
    let firstWorktree = try #require(tempRepository.worktrees.first)
    let secondWorktree = try #require(tempRepository.worktrees.dropFirst().first)
    let thirdWorktree = try #require(tempRepository.worktrees.dropFirst(2).first)
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .milliseconds(80),
      unfocusedInterval: .milliseconds(80),
      lineChangePhaseOffset: { worktreeID, _ in
        switch worktreeID {
        case secondWorktree.id:
          return .milliseconds(10)
        case thirdWorktree.id:
          return .milliseconds(40)
        default:
          return .zero
        }
      },
      pullRequestPhaseOffset: { _, _ in .zero },
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees([firstWorktree]))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: firstWorktree.id) == 1)

    manager.handleCommand(.setWorktrees([firstWorktree, secondWorktree, thirdWorktree]))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: secondWorktree.id) == 0)
    #expect(await collector.filesChangedCount(worktreeID: thirdWorktree.id) == 0)

    await clock.advance(by: .milliseconds(89))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: secondWorktree.id) == 0)
    #expect(await collector.filesChangedCount(worktreeID: thirdWorktree.id) == 0)

    await clock.advance(by: .milliseconds(1))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: secondWorktree.id) == 1)
    #expect(await collector.filesChangedCount(worktreeID: thirdWorktree.id) == 0)

    await clock.advance(by: .milliseconds(29))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: thirdWorktree.id) == 0)

    await clock.advance(by: .milliseconds(1))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: thirdWorktree.id) == 1)

    await clock.advance(by: .milliseconds(120))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: secondWorktree.id) == 1)
    #expect(await collector.filesChangedCount(worktreeID: thirdWorktree.id) == 1)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempRepository.tempRoot)
  }

  @Test func activeWorktreeRefreshesLineChangesAfterFileEventDebounce() async throws {
    let clock = TestClock()
    let tempRepository = try makeTempRepository(worktreeNames: ["sparrow", "swift"])
    let activeWorktree = try #require(tempRepository.worktrees.first)
    let inactiveWorktree = try #require(tempRepository.worktrees.dropFirst().first)
    let monitorStore = TestWorktreeFileEventMonitorStore()
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600),
      lineChangesEventDebounceInterval: .milliseconds(80),
      lineChangesSafetyRefreshInterval: .seconds(3_600),
      lineChangePhaseOffset: { _, _ in .zero },
      pullRequestPhaseOffset: { _, _ in .zero },
      worktreeFileEventMonitorFactory: monitorStore.makeMonitor,
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees([activeWorktree, inactiveWorktree]))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: activeWorktree.id) == 1)
    #expect(await collector.filesChangedCount(worktreeID: inactiveWorktree.id) == 1)
    #expect(monitorStore.monitor(for: activeWorktree.id) == nil)
    #expect(monitorStore.monitor(for: inactiveWorktree.id) == nil)

    manager.handleCommand(.setOpenedWorktreeIDs([activeWorktree.id]))
    let monitor = try #require(monitorStore.monitor(for: activeWorktree.id))
    #expect(monitorStore.monitor(for: inactiveWorktree.id) == nil)

    monitor.emit()
    await clock.advance(by: .milliseconds(79))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: activeWorktree.id) == 1)

    await clock.advance(by: .milliseconds(1))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: activeWorktree.id) == 2)
    #expect(await collector.filesChangedCount(worktreeID: inactiveWorktree.id) == 1)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempRepository.tempRoot)
  }

  @Test func activeWorktreeUsesSlowSafetyLineChangesRefresh() async throws {
    let clock = TestClock()
    let tempRepository = try makeTempRepository(worktreeNames: ["sparrow"])
    let worktree = try #require(tempRepository.worktrees.first)
    let monitorStore = TestWorktreeFileEventMonitorStore()
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600),
      lineChangesSafetyRefreshInterval: .milliseconds(80),
      lineChangePhaseOffset: { _, _ in .zero },
      pullRequestPhaseOffset: { _, _ in .zero },
      worktreeFileEventMonitorFactory: monitorStore.makeMonitor,
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees([worktree]))
    manager.handleCommand(.setOpenedWorktreeIDs([worktree.id]))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: worktree.id) == 1)

    await clock.advance(by: .milliseconds(79))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: worktree.id) == 1)

    await clock.advance(by: .milliseconds(1))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: worktree.id) == 2)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempRepository.tempRoot)
  }

  @Test func staggersPeriodicPullRequestRefreshAcrossRepositories() async throws {
    let clock = TestClock()
    let firstRepository = try makeTempRepository(worktreeNames: ["sparrow"])
    let secondRepository = try makeTempRepository(worktreeNames: ["swift"])
    let firstWorktree = try #require(firstRepository.worktrees.first)
    let secondWorktree = try #require(secondRepository.worktrees.first)
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .milliseconds(80),
      unfocusedInterval: .milliseconds(80),
      lineChangePhaseOffset: { _, _ in .zero },
      pullRequestPhaseOffset: { repositoryRootURL, _ in
        switch repositoryRootURL {
        case firstRepository.tempRoot:
          return .milliseconds(10)
        case secondRepository.tempRoot:
          return .milliseconds(40)
        default:
          return .zero
        }
      },
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setWorktrees([firstWorktree, secondWorktree]))
    await drainAsyncEvents(120)
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: firstRepository.tempRoot) == 1)
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: secondRepository.tempRoot) == 1)

    await clock.advance(by: .milliseconds(89))
    await drainAsyncEvents(120)
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: firstRepository.tempRoot) == 1)
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: secondRepository.tempRoot) == 1)

    await clock.advance(by: .milliseconds(1))
    await drainAsyncEvents(120)
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: firstRepository.tempRoot) == 2)
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: secondRepository.tempRoot) == 1)

    await clock.advance(by: .milliseconds(29))
    await drainAsyncEvents(120)
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: secondRepository.tempRoot) == 1)

    await clock.advance(by: .milliseconds(1))
    await drainAsyncEvents(120)
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: secondRepository.tempRoot) == 2)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: firstRepository.tempRoot)
    try FileManager.default.removeItem(at: secondRepository.tempRoot)
  }

  @Test func selectionRefreshUsesCooldownWithinRepository() async throws {
    let clock = TestClock()
    let tempRepository = try makeTempRepository(worktreeNames: ["sparrow", "swift"])
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600),
      pullRequestSelectionRefreshCooldown: .milliseconds(500),
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setWorktrees(tempRepository.worktrees))
    await drainAsyncEvents()
    let baselineCount = await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot)
    #expect(baselineCount == 1)
    let firstWorktree = try #require(tempRepository.worktrees.first)
    let secondWorktree = try #require(tempRepository.worktrees.dropFirst().first)

    await clock.advance(by: .milliseconds(500))
    await drainAsyncEvents()

    manager.handleCommand(.setSelectedWorktreeID(firstWorktree.id))
    await drainAsyncEvents()
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot) == baselineCount + 1)

    manager.handleCommand(.setSelectedWorktreeID(secondWorktree.id))
    await drainAsyncEvents()
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot) == baselineCount + 1)

    await clock.advance(by: .milliseconds(500))
    await drainAsyncEvents()

    manager.handleCommand(.setSelectedWorktreeID(firstWorktree.id))
    await drainAsyncEvents()
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot) == baselineCount + 2)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempRepository.tempRoot)
  }

  @Test func canceledSelectionCooldownDoesNotClearReplacementCooldown() async throws {
    let clock = TestClock()
    let tempRepository = try makeTempRepository(worktreeNames: ["sparrow", "swift"])
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600),
      pullRequestSelectionRefreshCooldown: .milliseconds(500),
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setWorktrees(tempRepository.worktrees))
    await drainAsyncEvents()
    let baselineCount = await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot)
    #expect(baselineCount == 1)

    let firstWorktree = try #require(tempRepository.worktrees.first)
    let secondWorktree = try #require(tempRepository.worktrees.dropFirst().first)

    manager.handleCommand(.setSelectedWorktreeID(firstWorktree.id))
    await drainAsyncEvents()
    let afterFirstSelectionCount = await collector.pullRequestRefreshCount(
      repositoryRootURL: tempRepository.tempRoot
    )
    #expect(afterFirstSelectionCount == baselineCount + 1)

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setPullRequestTrackingEnabled(true))
    manager.handleCommand(.setSelectedWorktreeID(secondWorktree.id))
    await drainAsyncEvents()
    let afterReplacementCooldownCount = await collector.pullRequestRefreshCount(
      repositoryRootURL: tempRepository.tempRoot
    )
    #expect(afterReplacementCooldownCount == afterFirstSelectionCount + 2)

    manager.handleCommand(.setSelectedWorktreeID(firstWorktree.id))
    await drainAsyncEvents()
    #expect(
      await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot)
        == afterReplacementCooldownCount
    )

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempRepository.tempRoot)
  }
}

actor EventCollector {
  private var events: [WorktreeInfoWatcherClient.Event] = []

  func append(_ event: WorktreeInfoWatcherClient.Event) {
    events.append(event)
  }

  func filesChangedCount(worktreeID: Worktree.ID) -> Int {
    events.reduce(into: 0) { result, event in
      if case .filesChanged(let id) = event, id == worktreeID {
        result += 1
      }
    }
  }

  func pullRequestRefreshCount(repositoryRootURL: URL) -> Int {
    events.reduce(into: 0) { result, event in
      if case .repositoryPullRequestRefresh(let rootURL, _) = event, rootURL == repositoryRootURL {
        result += 1
      }
    }
  }
}

private struct TempWorktree {
  let worktree: Worktree
  let tempRoot: URL
  let headURL: URL
}

private struct TempRepository {
  let worktrees: [Worktree]
  let tempRoot: URL
}

private func makeTempWorktree() throws -> TempWorktree {
  let fileManager = FileManager.default
  let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
  let worktreeDirectory = tempRoot.appending(path: "wt")
  let gitDirectory = worktreeDirectory.appending(path: ".git")
  try fileManager.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
  let headURL = gitDirectory.appending(path: "HEAD")
  try "ref: refs/heads/main\n".write(to: headURL, atomically: true, encoding: .utf8)
  let worktree = Worktree(
    id: worktreeDirectory.path(percentEncoded: false),
    name: "eagle",
    detail: "detail",
    workingDirectory: worktreeDirectory,
    repositoryRootURL: tempRoot
  )
  return TempWorktree(worktree: worktree, tempRoot: tempRoot, headURL: headURL)
}

private func makeTempRepository(worktreeNames: [String]) throws -> TempRepository {
  let fileManager = FileManager.default
  let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
  var worktrees: [Worktree] = []
  for name in worktreeNames {
    let worktreeDirectory = tempRoot.appending(path: name)
    let gitDirectory = worktreeDirectory.appending(path: ".git")
    try fileManager.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
    let headURL = gitDirectory.appending(path: "HEAD")
    try "ref: refs/heads/\(name)\n".write(to: headURL, atomically: true, encoding: .utf8)
    let worktree = Worktree(
      id: worktreeDirectory.path(percentEncoded: false),
      name: name,
      detail: "detail",
      workingDirectory: worktreeDirectory,
      repositoryRootURL: tempRoot
    )
    worktrees.append(worktree)
  }
  return TempRepository(worktrees: worktrees, tempRoot: tempRoot)
}

private func startCollecting(
  _ stream: AsyncStream<WorktreeInfoWatcherClient.Event>
) -> (EventCollector, Task<Void, Never>) {
  let collector = EventCollector()
  let task = Task {
    for await event in stream {
      if Task.isCancelled {
        break
      }
      await collector.append(event)
    }
  }
  return (collector, task)
}

private func drainAsyncEvents(_ iterations: Int = 20) async {
  for _ in 0..<iterations {
    await Task.yield()
  }
}

@MainActor
private final class TestWorktreeFileEventMonitorStore {
  private var monitors: [Worktree.ID: TestWorktreeFileEventMonitor] = [:]

  func makeMonitor(
    worktree: Worktree,
    onEvent: @escaping @MainActor @Sendable () -> Void
  ) -> WorktreeFileEventMonitoring? {
    let monitor = TestWorktreeFileEventMonitor(onEvent: onEvent)
    monitors[worktree.id] = monitor
    return monitor
  }

  func monitor(for worktreeID: Worktree.ID) -> TestWorktreeFileEventMonitor? {
    monitors[worktreeID]
  }
}

@MainActor
private final class TestWorktreeFileEventMonitor: WorktreeFileEventMonitoring {
  private let onEvent: @MainActor @Sendable () -> Void
  private(set) var isCanceled = false

  init(onEvent: @escaping @MainActor @Sendable () -> Void) {
    self.onEvent = onEvent
  }

  func emit() {
    onEvent()
  }

  func cancel() {
    isCanceled = true
  }
}
