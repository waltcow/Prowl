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

  @Test func detectsForegroundCommandInSameProcessGroup() throws {
    let selfPID = getpid()

    let process = Process()
    process.executableURL = URL(filePath: "/bin/sleep")
    process.arguments = ["60"]
    try process.run()
    let sleepPID = process.processIdentifier

    // macOS Process() may place the child in its own process group via posix_spawn.
    let childPgid = getpgid(sleepPID)
    #expect(childPgid > 0)

    let pidsWhileRunning = ProcessDetection.processGroupPIDs(childPgid)
    let hasLiveProcess = pidsWhileRunning.contains {
      $0 > 0 && $0 != selfPID && ProcessDetection.processBSDInfo(pid: $0) != nil
    }
    #expect(
      hasLiveProcess,
      "Expected to detect live process in pgid \(childPgid) but found: \(pidsWhileRunning)"
    )

    process.terminate()
    process.waitUntilExit()

    let pidsAfterExit = ProcessDetection.processGroupPIDs(childPgid)
    let hasLiveProcessAfterExit = pidsAfterExit.contains {
      $0 > 0 && $0 != selfPID && ProcessDetection.processBSDInfo(pid: $0) != nil
    }
    #expect(
      !hasLiveProcessAfterExit,
      "Expected no live process in pgid \(childPgid) after exit but found: \(pidsAfterExit)"
    )
  }
}
