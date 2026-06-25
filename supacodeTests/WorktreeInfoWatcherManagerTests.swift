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
      defaultLineChangesTiming: .init(filesChangedDebounce: .seconds(3_600), eventDebounce: .milliseconds(80)),
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

  @Test func repositoryRegistryEventRefreshesWorktreesAfterDebounce() async throws {
    let clock = TestClock()
    let tempRepository = try makeTempRepository(worktreeNames: ["sparrow"])
    let registryMonitorStore = TestWorktreeRegistryMonitorStore()
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600),
      repositoryWorktreesEventDebounceInterval: .milliseconds(80),
      lineChangePhaseOffset: { _, _ in .zero },
      pullRequestPhaseOffset: { _, _ in .zero },
      worktreeRegistryMonitorFactory: registryMonitorStore.makeMonitor,
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees(tempRepository.worktrees))
    await drainAsyncEvents(120)
    #expect(await collector.repositoryWorktreesChangedCount(repositoryRootURL: tempRepository.tempRoot) == 0)

    let monitor = try #require(registryMonitorStore.monitor(for: tempRepository.tempRoot))
    monitor.emit()
    await clock.advance(by: .milliseconds(79))
    await drainAsyncEvents(120)
    #expect(await collector.repositoryWorktreesChangedCount(repositoryRootURL: tempRepository.tempRoot) == 0)

    await clock.advance(by: .milliseconds(1))
    await drainAsyncEvents(120)
    #expect(await collector.repositoryWorktreesChangedCount(repositoryRootURL: tempRepository.tempRoot) == 1)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempRepository.tempRoot)
  }

  @Test func repositoryRemoteConfigEventEmitsChangedEventAfterDebounce() async throws {
    let clock = TestClock()
    let tempRepository = try makeTempRepository(worktreeNames: ["sparrow"])
    let remoteConfigMonitorStore = TestRemoteConfigMonitorStore()
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600),
      remoteConfigEventDebounceInterval: .milliseconds(80),
      lineChangePhaseOffset: { _, _ in .zero },
      pullRequestPhaseOffset: { _, _ in .zero },
      remoteConfigMonitorFactory: remoteConfigMonitorStore.makeMonitor,
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setWorktrees(tempRepository.worktrees))
    await drainAsyncEvents(120)
    #expect(await collector.repositoryRemoteConfigurationChangedCount(repositoryRootURL: tempRepository.tempRoot) == 0)

    let monitor = try #require(remoteConfigMonitorStore.monitor(for: tempRepository.tempRoot))
    monitor.emit()
    await clock.advance(by: .milliseconds(79))
    await drainAsyncEvents(120)
    #expect(await collector.repositoryRemoteConfigurationChangedCount(repositoryRootURL: tempRepository.tempRoot) == 0)

    await clock.advance(by: .milliseconds(1))
    await drainAsyncEvents(120)
    #expect(await collector.repositoryRemoteConfigurationChangedCount(repositoryRootURL: tempRepository.tempRoot) == 1)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempRepository.tempRoot)
  }

  @Test func removedRepositoryCancelsRegistryMonitor() async throws {
    let firstRepository = try makeTempRepository(worktreeNames: ["sparrow"])
    let secondRepository = try makeTempRepository(worktreeNames: ["swift"])
    let registryMonitorStore = TestWorktreeRegistryMonitorStore()
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600),
      worktreeRegistryMonitorFactory: registryMonitorStore.makeMonitor
    )
    let (_, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees(firstRepository.worktrees + secondRepository.worktrees))
    await drainAsyncEvents(120)
    let removedMonitor = try #require(registryMonitorStore.monitor(for: firstRepository.tempRoot))
    #expect(!removedMonitor.isCanceled)

    manager.handleCommand(.setWorktrees(secondRepository.worktrees))
    await drainAsyncEvents(120)
    #expect(removedMonitor.isCanceled)
    #expect(registryMonitorStore.monitor(for: secondRepository.tempRoot)?.isCanceled == false)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: firstRepository.tempRoot)
    try FileManager.default.removeItem(at: secondRepository.tempRoot)
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

    // Selecting first worktree triggers immediate refresh.
    manager.handleCommand(.setSelectedWorktreeID(firstWorktree.id))
    await drainAsyncEvents()
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot) == baselineCount + 1)

    // Switching to a different worktree cancels cooldown and triggers immediate refresh.
    manager.handleCommand(.setSelectedWorktreeID(secondWorktree.id))
    await drainAsyncEvents()
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot) == baselineCount + 2)

    // Switching back to first worktree also triggers immediate refresh (different worktree).
    manager.handleCommand(.setSelectedWorktreeID(firstWorktree.id))
    await drainAsyncEvents()
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot) == baselineCount + 3)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempRepository.tempRoot)
  }

  @Test func reselectingSameWorktreeRespectsCooldown() async throws {
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

    await clock.advance(by: .milliseconds(500))
    await drainAsyncEvents()

    // Selecting worktree triggers immediate refresh and starts cooldown.
    manager.handleCommand(.setSelectedWorktreeID(firstWorktree.id))
    await drainAsyncEvents()
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot) == baselineCount + 1)

    // Deselect then re-select the same worktree within cooldown — should NOT refresh.
    manager.handleCommand(.setSelectedWorktreeID(nil))
    await drainAsyncEvents()
    manager.handleCommand(.setSelectedWorktreeID(firstWorktree.id))
    await drainAsyncEvents()
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot) == baselineCount + 1)

    // After cooldown expires, re-selecting the same worktree should refresh.
    await clock.advance(by: .milliseconds(500))
    await drainAsyncEvents()
    manager.handleCommand(.setSelectedWorktreeID(nil))
    await drainAsyncEvents()
    manager.handleCommand(.setSelectedWorktreeID(firstWorktree.id))
    await drainAsyncEvents()
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot) == baselineCount + 2)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempRepository.tempRoot)
  }

  @Test func lineChangesTimingTierSelectsCorrectTier() {
    let small = WorktreeInfoWatcherManager.LineChangesTiming.tier(forIndexEntryCount: 500)
    #expect(small == .small)

    let smallBoundary = WorktreeInfoWatcherManager.LineChangesTiming.tier(forIndexEntryCount: 4_999)
    #expect(smallBoundary == .small)

    let medium = WorktreeInfoWatcherManager.LineChangesTiming.tier(forIndexEntryCount: 5_000)
    #expect(medium == .medium)

    let mediumBoundary = WorktreeInfoWatcherManager.LineChangesTiming.tier(forIndexEntryCount: 19_999)
    #expect(mediumBoundary == .medium)

    let large = WorktreeInfoWatcherManager.LineChangesTiming.tier(forIndexEntryCount: 20_000)
    #expect(large == .large)

    let veryLarge = WorktreeInfoWatcherManager.LineChangesTiming.tier(forIndexEntryCount: 100_000)
    #expect(veryLarge == .large)
  }

  @Test func largeRepoUsesLongerEventDebounce() async throws {
    let clock = TestClock()
    let tempRepository = try makeTempRepository(worktreeNames: ["sparrow"])
    let worktree = try #require(tempRepository.worktrees.first)
    let monitorStore = TestWorktreeFileEventMonitorStore()
    let largeTiming = WorktreeInfoWatcherManager.LineChangesTiming.large
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600),
      defaultLineChangesTiming: largeTiming,
      lineChangesSafetyRefreshInterval: .seconds(3_600),
      lineChangePhaseOffset: { _, _ in .zero },
      pullRequestPhaseOffset: { _, _ in .zero },
      worktreeFileEventMonitorFactory: monitorStore.makeMonitor,
      indexEntryCountProvider: { _ in nil },
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees([worktree]))
    manager.handleCommand(.setOpenedWorktreeIDs([worktree.id]))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: worktree.id) == 1)

    let monitor = try #require(monitorStore.monitor(for: worktree.id))
    monitor.emit()

    await clock.advance(by: largeTiming.eventDebounce - .milliseconds(1))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: worktree.id) == 1)

    await clock.advance(by: .milliseconds(1))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: worktree.id) == 2)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempRepository.tempRoot)
  }

  @Test func adaptiveTimingResolvesFromIndexEntryCount() async throws {
    let clock = TestClock()
    let tempRepository = try makeTempRepository(worktreeNames: ["sparrow"])
    let worktree = try #require(tempRepository.worktrees.first)
    let monitorStore = TestWorktreeFileEventMonitorStore()
    let mediumTiming = WorktreeInfoWatcherManager.LineChangesTiming.medium
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600),
      lineChangesSafetyRefreshInterval: .seconds(3_600),
      lineChangePhaseOffset: { _, _ in .zero },
      pullRequestPhaseOffset: { _, _ in .zero },
      worktreeFileEventMonitorFactory: monitorStore.makeMonitor,
      indexEntryCountProvider: { _ in 10_000 },
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees([worktree]))
    manager.handleCommand(.setOpenedWorktreeIDs([worktree.id]))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: worktree.id) == 1)

    let monitor = try #require(monitorStore.monitor(for: worktree.id))
    monitor.emit()

    await clock.advance(by: mediumTiming.eventDebounce - .milliseconds(1))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: worktree.id) == 1)

    await clock.advance(by: .milliseconds(1))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: worktree.id) == 2)

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

    // Switching back to first worktree triggers refresh (different worktree).
    manager.handleCommand(.setSelectedWorktreeID(firstWorktree.id))
    await drainAsyncEvents()
    #expect(
      await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot)
        == afterReplacementCooldownCount + 1
    )

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempRepository.tempRoot)
  }
  @Test func headWatcherEventNotBlockedByDeferredLineChanges() async throws {
    // Regression test: scheduleFilesChanged previously emitted .filesChanged
    // directly, which gets swallowed when the worktree is in deferredLineChangeIDs.
    // After the fix, it routes through scheduleLineChangesRefresh which calls
    // emitLineChangesChanged (clears deferred flag before emitting).
    let clock = TestClock()
    let tempRepository = try makeTempRepository(worktreeNames: ["sparrow", "swift"])
    let firstWorktree = try #require(tempRepository.worktrees.first)
    let secondWorktree = try #require(tempRepository.worktrees.dropFirst().first)
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600),
      defaultLineChangesTiming: .init(filesChangedDebounce: .milliseconds(80), eventDebounce: .seconds(3_600)),
      lineChangePhaseOffset: { _, _ in .zero },
      pullRequestPhaseOffset: { _, _ in .zero },
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    // Load only the first worktree initially — second will be deferred when added.
    manager.handleCommand(.setWorktrees([firstWorktree]))
    await drainAsyncEvents(120)
    let initialCount = await collector.filesChangedCount(worktreeID: firstWorktree.id)
    #expect(initialCount == 1)

    // Add second worktree — it goes into deferredLineChangeIDs.
    manager.handleCommand(.setWorktrees([firstWorktree, secondWorktree]))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: secondWorktree.id) == 0)

    // Simulate a commit by writing to HEAD file — triggers HEAD watcher.
    let headURL = secondWorktree.workingDirectory.appending(path: ".git/HEAD")
    try "ref: refs/heads/swift\n".write(to: headURL, atomically: true, encoding: .utf8)
    await drainAsyncEvents(120)

    // Even though secondWorktree is deferred, the event should fire after debounce.
    await clock.advance(by: .milliseconds(79))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: secondWorktree.id) == 0)

    await clock.advance(by: .milliseconds(1))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: secondWorktree.id) == 1)

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

  func repositoryWorktreesChangedCount(repositoryRootURL: URL) -> Int {
    let expectedURL = repositoryRootURL.standardizedFileURL
    return events.reduce(into: 0) { result, event in
      if case .repositoryWorktreesChanged(let rootURL) = event,
        rootURL.standardizedFileURL == expectedURL
      {
        result += 1
      }
    }
  }

  func repositoryRemoteConfigurationChangedCount(repositoryRootURL: URL) -> Int {
    let expectedURL = repositoryRootURL.standardizedFileURL
    return events.reduce(into: 0) { result, event in
      if case .repositoryRemoteConfigurationChanged(let rootURL) = event,
        rootURL.standardizedFileURL == expectedURL
      {
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

@MainActor
private final class TestWorktreeRegistryMonitorStore {
  private var monitors: [URL: TestWorktreeRegistryMonitor] = [:]

  func makeMonitor(
    repositoryRootURL: URL,
    onEvent: @escaping @MainActor @Sendable () -> Void
  ) -> WorktreeRegistryMonitoring? {
    let monitor = TestWorktreeRegistryMonitor(onEvent: onEvent)
    monitors[repositoryRootURL.standardizedFileURL] = monitor
    return monitor
  }

  func monitor(for repositoryRootURL: URL) -> TestWorktreeRegistryMonitor? {
    monitors[repositoryRootURL.standardizedFileURL]
  }
}

@MainActor
private final class TestWorktreeRegistryMonitor: WorktreeRegistryMonitoring {
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

@MainActor
private final class TestRemoteConfigMonitorStore {
  private var monitors: [URL: TestRemoteConfigMonitor] = [:]

  func makeMonitor(
    repositoryRootURL: URL,
    onEvent: @escaping @MainActor @Sendable () -> Void
  ) -> RemoteConfigMonitoring? {
    let monitor = TestRemoteConfigMonitor(onEvent: onEvent)
    monitors[repositoryRootURL.standardizedFileURL] = monitor
    return monitor
  }

  func monitor(for repositoryRootURL: URL) -> TestRemoteConfigMonitor? {
    monitors[repositoryRootURL.standardizedFileURL]
  }
}

@MainActor
private final class TestRemoteConfigMonitor: RemoteConfigMonitoring {
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
