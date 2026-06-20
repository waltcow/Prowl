import Darwin
import Foundation
import Testing

@testable import supacode

struct ProcessDetectionSmokeTests {
  @Test func readsCurrentProcessArguments() throws {
    let pid = getpid()

    let argv0 = try #require(ProcessDetection.processArgv0Name(pid: pid))
    let cmdline = try #require(ProcessDetection.processCommandLine(pid: pid))
    let info = try #require(ProcessDetection.processBSDInfo(pid: pid))
    let comm = try #require(ProcessDetection.comm(from: info))

    #expect(!argv0.isEmpty)
    #expect(!cmdline.isEmpty)
    #expect(!comm.isEmpty)
  }

  @Test func listsCurrentProcessGroupWithoutScanningAllProcesses() {
    let pids = ProcessDetection.processGroupPIDs(getpgrp())

    #expect(pids.contains(getpid()))
  }

  /// Validates that ProcessDetection can detect a foreground command running
  /// in a process group and correctly reports the group as empty after exit.
  ///
  /// On macOS, Process() may place the child in its own process group (via
  /// posix_spawn), so we look up the child's pgid rather than assuming it
  /// matches the test process's group.
  @Test func detectsForegroundCommandInSameProcessGroup() async throws {
    let selfPID = getpid()

    // Spawn `sleep 3` — macOS Process() may place it in its own process group.
    let process = Process()
    process.executableURL = URL(filePath: "/bin/sleep")
    process.arguments = ["3"]
    try process.run()
    let sleepPID = process.processIdentifier

    // Find the child's actual process group (may differ from our pgid on macOS).
    let childPgid = getpgid(sleepPID)
    #expect(childPgid > 0)

    // While sleep is running, its process group should contain at least one
    // live process (the sleep process itself).
    let pidsWhileRunning = ProcessDetection.processGroupPIDs(childPgid)
    let hasLiveProcessWhileRunning = pidsWhileRunning.contains {
      $0 > 0 && $0 != selfPID && ProcessDetection.processBSDInfo(pid: $0) != nil
    }
    #expect(
      hasLiveProcessWhileRunning,
      "Expected to detect live process in pgid \(childPgid) but found: \(pidsWhileRunning)"
    )

    // Wait for sleep to exit.
    process.waitUntilExit()

    // After sleep exits, the process group should have no other live processes.
    try await Task.sleep(for: .milliseconds(100))

    let pidsAfterExit = ProcessDetection.processGroupPIDs(childPgid)
    let hasLiveProcessAfterExit = pidsAfterExit.contains {
      $0 > 0 && $0 != selfPID && ProcessDetection.processBSDInfo(pid: $0) != nil
    }
    #expect(
      !hasLiveProcessAfterExit,
      "Expected no live process in pgid \(childPgid) after sleep exited but found: \(pidsAfterExit)"
    )
  }
}
