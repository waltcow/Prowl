import CoreServices
import Darwin
import Dispatch
import Foundation

@MainActor
protocol WorktreeFileEventMonitoring: AnyObject {
  func cancel()
}

@MainActor
final class WorktreeInfoWatcherManager {
  typealias WorktreePhaseOffset = @Sendable (Worktree.ID, Duration) -> Duration
  typealias RepositoryPhaseOffset = @Sendable (URL, Duration) -> Duration
  typealias WorktreeFileEventMonitorFactory =
    @MainActor @Sendable (
      _ worktree: Worktree,
      _ onEvent: @escaping @MainActor @Sendable () -> Void
    ) -> WorktreeFileEventMonitoring?

  private struct HeadWatcher {
    let headURL: URL
    let source: DispatchSourceFileSystemObject
  }

  private struct RefreshTask {
    let interval: Duration
    let task: Task<Void, Never>
  }

  private struct PullRequestSelectionCooldownTask {
    let id: UUID
    let task: Task<Void, Never>
  }

  private struct RepeatingTaskRequest {
    let worktreeID: Worktree.ID
    let interval: Duration
    let initialDelay: Duration
    let immediate: Bool
    let forceReschedule: Bool
    let makeEvent: (Worktree.ID) -> WorktreeInfoWatcherClient.Event?
  }

  private struct RefreshTiming: Equatable {
    let focused: Duration
    let unfocused: Duration
  }

  private let filesChangedDebounceInterval: Duration
  private let lineChangesEventDebounceInterval: Duration
  private let lineChangesSafetyRefreshInterval: Duration
  private let pullRequestSelectionRefreshCooldown: Duration
  private let refreshTiming: RefreshTiming
  private let lineChangePhaseOffset: WorktreePhaseOffset
  private let pullRequestPhaseOffset: RepositoryPhaseOffset
  private let worktreeFileEventMonitorFactory: WorktreeFileEventMonitorFactory
  private let sleep: @Sendable (Duration) async throws -> Void
  private var worktrees: [Worktree.ID: Worktree] = [:]
  private var headWatchers: [Worktree.ID: HeadWatcher] = [:]
  private var worktreeFileEventMonitors: [Worktree.ID: WorktreeFileEventMonitoring] = [:]
  private var branchDebounceTasks: [Worktree.ID: Task<Void, Never>] = [:]
  private var filesDebounceTasks: [Worktree.ID: Task<Void, Never>] = [:]
  private var restartTasks: [Worktree.ID: Task<Void, Never>] = [:]
  private var pullRequestTasks: [URL: RefreshTask] = [:]
  private var lineChangeSafetyTasks: [Worktree.ID: RefreshTask] = [:]
  private var lineChangeRefreshTasks: [Worktree.ID: Task<Void, Never>] = [:]
  private var deferredLineChangeIDs: Set<Worktree.ID> = []
  private var openedWorktreeIDs: Set<Worktree.ID> = []
  private var hasCompletedInitialWorktreeLoad = false
  private var selectedWorktreeID: Worktree.ID?
  private var pullRequestTrackingEnabled = true
  private var pullRequestSelectionCooldownTasksByRepo: [URL: PullRequestSelectionCooldownTask] = [:]
  private var eventContinuation: AsyncStream<WorktreeInfoWatcherClient.Event>.Continuation?

  init<C: Clock<Duration>>(
    focusedInterval: Duration = .seconds(30),
    unfocusedInterval: Duration = .seconds(60),
    filesChangedDebounceInterval: Duration = .seconds(5),
    lineChangesEventDebounceInterval: Duration = .seconds(30),
    lineChangesSafetyRefreshInterval: Duration = .seconds(300),
    pullRequestSelectionRefreshCooldown: Duration = .seconds(5),
    lineChangePhaseOffset: @escaping WorktreePhaseOffset = WorktreeInfoWatcherManager.defaultLineChangePhaseOffset,
    pullRequestPhaseOffset: @escaping RepositoryPhaseOffset = WorktreeInfoWatcherManager.defaultPullRequestPhaseOffset,
    worktreeFileEventMonitorFactory: @escaping WorktreeFileEventMonitorFactory =
      WorktreeInfoWatcherManager.defaultWorktreeFileEventMonitorFactory,
    clock: C = ContinuousClock()
  ) {
    refreshTiming = RefreshTiming(focused: focusedInterval, unfocused: unfocusedInterval)
    self.filesChangedDebounceInterval = filesChangedDebounceInterval
    self.lineChangesEventDebounceInterval = lineChangesEventDebounceInterval
    self.lineChangesSafetyRefreshInterval = lineChangesSafetyRefreshInterval
    self.pullRequestSelectionRefreshCooldown = pullRequestSelectionRefreshCooldown
    self.lineChangePhaseOffset = lineChangePhaseOffset
    self.pullRequestPhaseOffset = pullRequestPhaseOffset
    self.worktreeFileEventMonitorFactory = worktreeFileEventMonitorFactory
    self.sleep = { duration in
      try await clock.sleep(for: duration)
    }
  }

  func handleCommand(_ command: WorktreeInfoWatcherClient.Command) {
    switch command {
    case .setWorktrees(let worktrees):
      setWorktrees(worktrees)
    case .setOpenedWorktreeIDs(let worktreeIDs):
      setOpenedWorktreeIDs(worktreeIDs)
    case .setSelectedWorktreeID(let worktreeID):
      setSelectedWorktreeID(worktreeID)
    case .refreshLineChanges:
      scheduleLineChangesRefreshForAllWorktrees()
    case .setPullRequestTrackingEnabled(let isEnabled):
      setPullRequestTrackingEnabled(isEnabled)
    case .stop:
      stopAll()
    }
  }

  func eventStream() -> AsyncStream<WorktreeInfoWatcherClient.Event> {
    eventContinuation?.finish()
    let (stream, continuation) = AsyncStream.makeStream(of: WorktreeInfoWatcherClient.Event.self)
    eventContinuation = continuation
    return stream
  }

  private func setWorktrees(_ worktrees: [Worktree]) {
    let isInitialWorktreeLoad = !hasCompletedInitialWorktreeLoad && self.worktrees.isEmpty && !worktrees.isEmpty
    let worktreesByID = Dictionary(uniqueKeysWithValues: worktrees.map { ($0.id, $0) })
    let desiredIDs = Set(worktreesByID.keys)
    let currentIDs = Set(self.worktrees.keys)
    let removedIDs = currentIDs.subtracting(desiredIDs)
    for id in removedIDs {
      stopWatcher(for: id)
    }
    if !removedIDs.isEmpty {
      deferredLineChangeIDs.subtract(removedIDs)
      openedWorktreeIDs.subtract(removedIDs)
    }
    let newIDs = desiredIDs.subtracting(currentIDs)
    if !newIDs.isEmpty && !isInitialWorktreeLoad {
      deferredLineChangeIDs.formUnion(newIDs)
    }
    self.worktrees = worktreesByID
    for worktree in worktrees {
      configureWatcher(for: worktree)
      if isInitialWorktreeLoad || !deferredLineChangeIDs.contains(worktree.id) {
        emitLineChangesChanged(worktreeID: worktree.id)
      } else if newIDs.contains(worktree.id) {
        scheduleLineChangesRefresh(worktreeID: worktree.id, delay: deferredLineChangesRefreshDelay(for: worktree))
      }
      syncLineChangesActivity(for: worktree.id)
    }
    if isInitialWorktreeLoad {
      hasCompletedInitialWorktreeLoad = true
    }
    let repositoryRoots = Set(worktrees.map(\.repositoryRootURL))
    for repositoryRootURL in repositoryRoots {
      updatePullRequestSchedule(repositoryRootURL: repositoryRootURL, immediate: true)
    }
    let obsoleteRepositories = pullRequestTasks.keys.filter { !repositoryRoots.contains($0) }
    for repositoryRootURL in obsoleteRepositories {
      pullRequestTasks.removeValue(forKey: repositoryRootURL)?.task.cancel()
    }
    let obsoleteCooldownRepositories = pullRequestSelectionCooldownTasksByRepo.keys.filter {
      !repositoryRoots.contains($0)
    }
    for repositoryRootURL in obsoleteCooldownRepositories {
      cancelPullRequestSelectionCooldown(for: repositoryRootURL)
    }
  }

  private func setOpenedWorktreeIDs(_ worktreeIDs: Set<Worktree.ID>) {
    let validIDs = worktreeIDs.intersection(worktrees.keys)
    guard validIDs != openedWorktreeIDs else {
      return
    }
    let affectedIDs = openedWorktreeIDs.symmetricDifference(validIDs)
    openedWorktreeIDs = validIDs
    for worktreeID in affectedIDs {
      syncLineChangesActivity(for: worktreeID)
    }
  }

  private func setSelectedWorktreeID(_ worktreeID: Worktree.ID?) {
    guard selectedWorktreeID != worktreeID else {
      return
    }
    let previousWorktreeID = selectedWorktreeID
    let previousRepository = previousWorktreeID.flatMap { worktrees[$0]?.repositoryRootURL }
    selectedWorktreeID = worktreeID
    let nextRepository = worktreeID.flatMap { worktrees[$0]?.repositoryRootURL }
    if let previousWorktreeID {
      syncLineChangesActivity(for: previousWorktreeID)
    }
    if let worktreeID {
      emitLineChangesChanged(worktreeID: worktreeID)
      syncLineChangesActivity(for: worktreeID)
    }
    if let previousRepository, previousRepository == nextRepository {
      updatePullRequestSchedule(
        repositoryRootURL: previousRepository,
        immediate: shouldImmediatelyRefreshPullRequests(repositoryRootURL: previousRepository)
      )
      return
    }
    if let previousRepository {
      updatePullRequestSchedule(repositoryRootURL: previousRepository, immediate: false)
    }
    if let nextRepository {
      updatePullRequestSchedule(
        repositoryRootURL: nextRepository,
        immediate: shouldImmediatelyRefreshPullRequests(repositoryRootURL: nextRepository)
      )
    }
  }

  private func configureWatcher(for worktree: Worktree) {
    guard
      let headURL = GitWorktreeHeadResolver.headURL(
        for: worktree.workingDirectory,
        fileManager: .default
      )
    else {
      stopWatcher(for: worktree.id)
      return
    }
    if let existing = headWatchers[worktree.id], existing.headURL == headURL {
      return
    }
    stopWatcher(for: worktree.id)
    startWatcher(worktreeID: worktree.id, headURL: headURL)
  }

  private func startWatcher(worktreeID: Worktree.ID, headURL: URL) {
    let path = headURL.path(percentEncoded: false)
    let fileDescriptor = open(path, O_EVTONLY)
    guard fileDescriptor >= 0 else {
      return
    }
    let queue = DispatchQueue(label: "worktree-info-watcher.\(worktreeID)")
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fileDescriptor,
      eventMask: [.write, .rename, .delete, .attrib],
      queue: queue
    )
    source.setEventHandler { @Sendable [weak self, weak source] in
      guard let source else { return }
      let event = source.data
      Task { @MainActor in
        self?.handleEvent(worktreeID: worktreeID, event: event)
      }
    }
    source.setCancelHandler { @Sendable in
      close(fileDescriptor)
    }
    source.resume()
    headWatchers[worktreeID] = HeadWatcher(headURL: headURL, source: source)
  }

  private func handleEvent(
    worktreeID: Worktree.ID,
    event: DispatchSource.FileSystemEvent
  ) {
    if event.contains(.delete) || event.contains(.rename) {
      stopHeadWatcher(for: worktreeID)
      scheduleRestart(worktreeID: worktreeID)
      scheduleBranchChanged(worktreeID: worktreeID)
      return
    }
    scheduleBranchChanged(worktreeID: worktreeID)
    scheduleFilesChanged(worktreeID: worktreeID)
  }

  private func scheduleBranchChanged(worktreeID: Worktree.ID) {
    branchDebounceTasks[worktreeID]?.cancel()
    let sleep = self.sleep
    let task = Task { [weak self, sleep] in
      try? await sleep(.milliseconds(200))
      await MainActor.run {
        self?.emit(.branchChanged(worktreeID: worktreeID))
      }
    }
    branchDebounceTasks[worktreeID] = task
  }

  private func scheduleFilesChanged(worktreeID: Worktree.ID) {
    filesDebounceTasks[worktreeID]?.cancel()
    let debounceInterval = filesChangedDebounceInterval
    let sleep = self.sleep
    let task = Task { [weak self, sleep] in
      try? await sleep(debounceInterval)
      await MainActor.run {
        guard let self else { return }
        self.emit(.filesChanged(worktreeID: worktreeID))
      }
    }
    filesDebounceTasks[worktreeID] = task
  }

  private func scheduleRestart(worktreeID: Worktree.ID) {
    restartTasks[worktreeID]?.cancel()
    let sleep = self.sleep
    let task = Task { [weak self, sleep] in
      try? await sleep(.seconds(5))
      await MainActor.run {
        self?.restartWatcher(worktreeID: worktreeID)
      }
    }
    restartTasks[worktreeID] = task
  }

  private func restartWatcher(worktreeID: Worktree.ID) {
    guard headWatchers[worktreeID] == nil else {
      return
    }
    guard let worktree = worktrees[worktreeID] else {
      return
    }
    configureWatcher(for: worktree)
    scheduleBranchChanged(worktreeID: worktreeID)
  }

  private func stopHeadWatcher(for worktreeID: Worktree.ID) {
    if let watcher = headWatchers.removeValue(forKey: worktreeID) {
      watcher.source.cancel()
    }
  }

  private func stopWatcher(for worktreeID: Worktree.ID) {
    stopHeadWatcher(for: worktreeID)
    stopWorktreeFileEventMonitor(for: worktreeID)
    branchDebounceTasks.removeValue(forKey: worktreeID)?.cancel()
    filesDebounceTasks.removeValue(forKey: worktreeID)?.cancel()
    restartTasks.removeValue(forKey: worktreeID)?.cancel()
    lineChangeSafetyTasks.removeValue(forKey: worktreeID)?.task.cancel()
    lineChangeRefreshTasks.removeValue(forKey: worktreeID)?.cancel()
  }

  private func stopAll() {
    for watcher in headWatchers.values {
      watcher.source.cancel()
    }
    for task in branchDebounceTasks.values {
      task.cancel()
    }
    for task in filesDebounceTasks.values {
      task.cancel()
    }
    for task in restartTasks.values {
      task.cancel()
    }
    for task in pullRequestTasks.values {
      task.task.cancel()
    }
    for task in lineChangeSafetyTasks.values {
      task.task.cancel()
    }
    for task in lineChangeRefreshTasks.values {
      task.cancel()
    }
    for monitor in worktreeFileEventMonitors.values {
      monitor.cancel()
    }
    headWatchers.removeAll()
    worktreeFileEventMonitors.removeAll()
    branchDebounceTasks.removeAll()
    filesDebounceTasks.removeAll()
    restartTasks.removeAll()
    pullRequestTasks.removeAll()
    lineChangeSafetyTasks.removeAll()
    lineChangeRefreshTasks.removeAll()
    deferredLineChangeIDs.removeAll()
    openedWorktreeIDs.removeAll()
    hasCompletedInitialWorktreeLoad = false
    cancelAllPullRequestSelectionCooldownTasks()
    worktrees.removeAll()
    selectedWorktreeID = nil
    pullRequestTrackingEnabled = true
    eventContinuation?.finish()
  }

  private func setPullRequestTrackingEnabled(_ enabled: Bool) {
    guard pullRequestTrackingEnabled != enabled else {
      return
    }
    pullRequestTrackingEnabled = enabled
    if enabled {
      let repositoryRoots = Set(worktrees.values.map(\.repositoryRootURL))
      for repositoryRootURL in repositoryRoots {
        updatePullRequestSchedule(repositoryRootURL: repositoryRootURL, immediate: true)
      }
      return
    }
    for task in pullRequestTasks.values {
      task.task.cancel()
    }
    pullRequestTasks.removeAll()
    cancelAllPullRequestSelectionCooldownTasks()
  }

  private func updatePullRequestSchedule(repositoryRootURL: URL, immediate: Bool) {
    guard pullRequestTrackingEnabled else {
      pullRequestTasks.removeValue(forKey: repositoryRootURL)?.task.cancel()
      return
    }
    let worktreeIDs = repositoryWorktreeIDs(for: repositoryRootURL)
    guard !worktreeIDs.isEmpty else {
      pullRequestTasks.removeValue(forKey: repositoryRootURL)?.task.cancel()
      return
    }
    let isFocused = selectedWorktreeID.map { worktreeIDs.contains($0) } ?? false
    let interval = isFocused ? refreshTiming.focused : refreshTiming.unfocused
    if let existing = pullRequestTasks[repositoryRootURL], existing.interval == interval, !immediate {
      return
    }
    pullRequestTasks[repositoryRootURL]?.task.cancel()
    if immediate {
      emitPullRequestRefresh(repositoryRootURL: repositoryRootURL)
    }
    let initialDelay = interval + pullRequestPhaseOffset(repositoryRootURL, interval)
    let sleep = self.sleep
    let task = Task { [weak self, sleep] in
      do {
        try await sleep(initialDelay)
      } catch {
        return
      }
      while !Task.isCancelled {
        await MainActor.run {
          self?.emitPullRequestRefresh(repositoryRootURL: repositoryRootURL)
        }
        do {
          try await sleep(interval)
        } catch {
          return
        }
      }
    }
    pullRequestTasks[repositoryRootURL] = RefreshTask(interval: interval, task: task)
  }

  private func repositoryWorktreeIDs(for repositoryRootURL: URL) -> [Worktree.ID] {
    worktrees
      .values
      .filter { $0.repositoryRootURL == repositoryRootURL }
      .map(\.id)
      .sorted()
  }

  private func emitPullRequestRefresh(repositoryRootURL: URL) {
    guard pullRequestTrackingEnabled else {
      return
    }
    let worktreeIDs = repositoryWorktreeIDs(for: repositoryRootURL)
    guard !worktreeIDs.isEmpty else {
      return
    }
    emit(.repositoryPullRequestRefresh(repositoryRootURL: repositoryRootURL, worktreeIDs: worktreeIDs))
  }

  private func scheduleLineChangesRefreshForAllWorktrees() {
    for worktree in worktrees.values {
      scheduleLineChangesRefresh(worktreeID: worktree.id, delay: lineChangesRefreshDelay(for: worktree))
    }
  }

  private func scheduleLineChangesRefresh(
    worktreeID: Worktree.ID,
    delay: Duration
  ) {
    guard worktrees[worktreeID] != nil else {
      return
    }
    lineChangeRefreshTasks[worktreeID]?.cancel()
    let sleep = self.sleep
    let task = Task { [weak self, sleep] in
      do {
        try await sleep(delay)
      } catch {
        return
      }
      await MainActor.run {
        self?.lineChangeRefreshTasks.removeValue(forKey: worktreeID)
        self?.emitLineChangesChanged(worktreeID: worktreeID)
      }
    }
    lineChangeRefreshTasks[worktreeID] = task
  }

  private func scheduleLineChangesDebouncedRefresh(worktreeID: Worktree.ID) {
    scheduleLineChangesRefresh(worktreeID: worktreeID, delay: lineChangesEventDebounceInterval)
  }

  private func updateLineChangesSafetySchedule(worktreeID: Worktree.ID) {
    guard isLineChangesActive(worktreeID), worktrees[worktreeID] != nil else {
      lineChangeSafetyTasks.removeValue(forKey: worktreeID)?.task.cancel()
      return
    }
    let request = RepeatingTaskRequest(
      worktreeID: worktreeID,
      interval: lineChangesSafetyRefreshInterval,
      initialDelay: lineChangesSafetyRefreshInterval,
      immediate: false,
      forceReschedule: false,
      makeEvent: { [weak self] worktreeID in
        self?.makeLineChangesChangedEvent(worktreeID: worktreeID)
      }
    )
    updateRepeatingTask(request, tasks: &lineChangeSafetyTasks)
  }

  private func lineChangesRefreshDelay(for worktree: Worktree) -> Duration {
    let interval = worktree.id == selectedWorktreeID ? refreshTiming.focused : refreshTiming.unfocused
    return lineChangePhaseOffset(worktree.id, interval)
  }

  private func deferredLineChangesRefreshDelay(for worktree: Worktree) -> Duration {
    let interval = worktree.id == selectedWorktreeID ? refreshTiming.focused : refreshTiming.unfocused
    return interval + lineChangePhaseOffset(worktree.id, interval)
  }

  private func emitLineChangesChanged(worktreeID: Worktree.ID) {
    guard let event = makeLineChangesChangedEvent(worktreeID: worktreeID) else {
      return
    }
    emit(event)
  }

  private func makeLineChangesChangedEvent(worktreeID: Worktree.ID) -> WorktreeInfoWatcherClient.Event? {
    guard worktrees[worktreeID] != nil else {
      return nil
    }
    deferredLineChangeIDs.remove(worktreeID)
    return .filesChanged(worktreeID: worktreeID)
  }

  private func syncLineChangesActivity(for worktreeID: Worktree.ID) {
    guard let worktree = worktrees[worktreeID], isLineChangesActive(worktreeID) else {
      stopWorktreeFileEventMonitor(for: worktreeID)
      lineChangeSafetyTasks.removeValue(forKey: worktreeID)?.task.cancel()
      return
    }
    startWorktreeFileEventMonitorIfNeeded(for: worktree)
    updateLineChangesSafetySchedule(worktreeID: worktreeID)
  }

  private func isLineChangesActive(_ worktreeID: Worktree.ID) -> Bool {
    selectedWorktreeID == worktreeID || openedWorktreeIDs.contains(worktreeID)
  }

  private func startWorktreeFileEventMonitorIfNeeded(for worktree: Worktree) {
    guard worktreeFileEventMonitors[worktree.id] == nil else {
      return
    }
    worktreeFileEventMonitors[worktree.id] = worktreeFileEventMonitorFactory(worktree) { [weak self] in
      self?.scheduleLineChangesDebouncedRefresh(worktreeID: worktree.id)
    }
  }

  private func stopWorktreeFileEventMonitor(for worktreeID: Worktree.ID) {
    worktreeFileEventMonitors.removeValue(forKey: worktreeID)?.cancel()
  }

  private func updateRepeatingTask(
    _ request: RepeatingTaskRequest,
    tasks: inout [Worktree.ID: RefreshTask]
  ) {
    let worktreeID = request.worktreeID
    if let existing = tasks[worktreeID], existing.interval == request.interval, !request.forceReschedule {
      if request.immediate {
        if let event = request.makeEvent(worktreeID) {
          emit(event)
        }
      }
      return
    }
    tasks[worktreeID]?.task.cancel()
    if request.immediate {
      if let event = request.makeEvent(worktreeID) {
        emit(event)
      }
    }
    let sleep = self.sleep
    let task = Task { [weak self, sleep] in
      do {
        try await sleep(request.initialDelay)
      } catch {
        return
      }
      while !Task.isCancelled {
        await MainActor.run {
          guard let event = request.makeEvent(worktreeID) else {
            return
          }
          self?.emit(event)
        }
        do {
          try await sleep(request.interval)
        } catch {
          return
        }
      }
    }
    tasks[worktreeID] = RefreshTask(interval: request.interval, task: task)
  }

  nonisolated private static func defaultLineChangePhaseOffset(
    worktreeID: Worktree.ID,
    interval: Duration
  ) -> Duration {
    stablePhaseOffset(seed: worktreeID, interval: interval)
  }

  nonisolated private static func defaultPullRequestPhaseOffset(
    repositoryRootURL: URL,
    interval: Duration
  ) -> Duration {
    stablePhaseOffset(seed: repositoryRootURL.path(percentEncoded: false), interval: interval)
  }

  private static func defaultWorktreeFileEventMonitorFactory(
    worktree: Worktree,
    onEvent: @escaping @MainActor @Sendable () -> Void
  ) -> WorktreeFileEventMonitoring? {
    FSEventsWorktreeFileEventMonitor(rootURL: worktree.workingDirectory, onEvent: onEvent)
  }

  nonisolated private static func stablePhaseOffset(seed: String, interval: Duration) -> Duration {
    let intervalMilliseconds = durationMilliseconds(interval)
    guard intervalMilliseconds > 0 else {
      return .zero
    }
    let hash = stableHash(seed)
    return .milliseconds(Int64(hash % UInt64(intervalMilliseconds)))
  }

  nonisolated private static func durationMilliseconds(_ duration: Duration) -> Int64 {
    let components = duration.components
    let millisecondsFromSeconds = components.seconds * 1_000
    let millisecondsFromAttoseconds = Int64(components.attoseconds / 1_000_000_000_000_000)
    return millisecondsFromSeconds + millisecondsFromAttoseconds
  }

  nonisolated private static func stableHash(_ string: String) -> UInt64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in string.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return hash
  }

  private func emit(_ event: WorktreeInfoWatcherClient.Event) {
    if case .filesChanged(let worktreeID) = event,
      deferredLineChangeIDs.contains(worktreeID)
    {
      return
    }
    eventContinuation?.yield(event)
  }

  private func cancelPullRequestSelectionCooldown(for repositoryRootURL: URL) {
    pullRequestSelectionCooldownTasksByRepo.removeValue(forKey: repositoryRootURL)?.task.cancel()
  }

  private func cancelAllPullRequestSelectionCooldownTasks() {
    for task in pullRequestSelectionCooldownTasksByRepo.values {
      task.task.cancel()
    }
    pullRequestSelectionCooldownTasksByRepo.removeAll()
  }

  private func shouldImmediatelyRefreshPullRequests(repositoryRootURL: URL) -> Bool {
    guard pullRequestSelectionCooldownTasksByRepo[repositoryRootURL] == nil else {
      return false
    }
    let cooldown = pullRequestSelectionRefreshCooldown
    let sleep = self.sleep
    let taskID = UUID()
    let task = Task { [weak self, sleep, taskID] in
      do {
        try await sleep(cooldown)
      } catch {
        return
      }
      await MainActor.run {
        guard
          let self,
          self.pullRequestSelectionCooldownTasksByRepo[repositoryRootURL]?.id == taskID
        else {
          return
        }
        self.pullRequestSelectionCooldownTasksByRepo.removeValue(forKey: repositoryRootURL)
      }
    }
    pullRequestSelectionCooldownTasksByRepo[repositoryRootURL] = PullRequestSelectionCooldownTask(
      id: taskID,
      task: task
    )
    return true
  }
}

private final class FSEventsWorktreeFileEventMonitor: WorktreeFileEventMonitoring {
  private let onEvent: @MainActor @Sendable () -> Void
  private var stream: FSEventStreamRef?

  init?(
    rootURL: URL,
    onEvent: @escaping @MainActor @Sendable () -> Void
  ) {
    self.onEvent = onEvent
    let path = rootURL.path(percentEncoded: false)
    var context = FSEventStreamContext(
      version: 0,
      info: nil,
      retain: nil,
      release: nil,
      copyDescription: nil
    )
    context.info = Unmanaged.passUnretained(self).toOpaque()
    let callback: FSEventStreamCallback = { _, callbackInfo, _, _, _, _ in
      guard let callbackInfo else { return }
      let monitor = Unmanaged<FSEventsWorktreeFileEventMonitor>
        .fromOpaque(callbackInfo)
        .takeUnretainedValue()
      Task { @MainActor in
        monitor.onEvent()
      }
    }
    stream = FSEventStreamCreate(
      nil,
      callback,
      &context,
      [path] as CFArray,
      FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
      1.0,
      FSEventStreamCreateFlags(
        kFSEventStreamCreateFlagFileEvents
          | kFSEventStreamCreateFlagNoDefer
          | kFSEventStreamCreateFlagWatchRoot
      )
    )
    guard let stream else {
      return nil
    }
    FSEventStreamScheduleWithRunLoop(
      stream,
      CFRunLoopGetMain(),
      CFRunLoopMode.defaultMode.rawValue
    )
    guard FSEventStreamStart(stream) else {
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      self.stream = nil
      return nil
    }
  }

  func cancel() {
    guard let stream else {
      return
    }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    self.stream = nil
  }
}
