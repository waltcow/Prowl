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

  /// When the shell runs a foreground command (e.g. `sleep 60`), the command
  /// joins the shell's process group — `tcgetpgrp` does NOT return a new pgid.
  /// The only way to tell that work is happening is to check whether the
  /// foreground process group contains any processes **besides the shell itself**.
  ///
  /// This test validates that signal: spawn `sleep 3` as a child in the same
  /// process group, verify we see >1 process, then wait for it to exit and
  /// verify the group collapses back to just us.
  @Test func detectsForegroundCommandInSameProcessGroup() async throws {
    let selfPID = getpid()
    let myPgid = getpgrp()

    // Spawn `sleep 3` in our process group (the same pattern a shell uses for
    // foreground commands).
    let process = Process()
    process.executableURL = URL(filePath: "/bin/sleep")
    process.arguments = ["3"]
    try process.run()
    let sleepPID = process.processIdentifier

    // Ensure the child is in our process group (should be inherited).
    let childPgid = getpgid(sleepPID)
    #expect(childPgid == myPgid)

    // While sleep is running, the process group should contain at least 2
    // live processes: ourselves and sleep.
    let pidsWhileRunning = ProcessDetection.processGroupPIDs(myPgid)
    let hasOtherProcessWhileRunning = pidsWhileRunning.contains {
      $0 > 0 && $0 != selfPID && ProcessDetection.processBSDInfo(pid: $0) != nil
    }
    #expect(hasOtherProcessWhileRunning, "Expected to detect sleep in pgid \(myPgid) but found: \(pidsWhileRunning)")

    // Wait for sleep to exit.
    process.waitUntilExit()

    // After sleep exits, the only live process in our pgid should be ourselves.
    // Give the kernel a moment to reap.
    try await Task.sleep(for: .milliseconds(100))

    let pidsAfterExit = ProcessDetection.processGroupPIDs(myPgid)
    let hasOtherProcessAfterExit = pidsAfterExit.contains {
      $0 > 0 && $0 != selfPID && ProcessDetection.processBSDInfo(pid: $0) != nil
    }
    #expect(
      !hasOtherProcessAfterExit,
      "Expected no other process in pgid \(myPgid) after sleep exited but found: \(pidsAfterExit)"
    )
  }
}
