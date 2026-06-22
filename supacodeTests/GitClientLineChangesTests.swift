import Foundation
import Testing

@testable import supacode

actor LineChangesShellCallStore {
  private(set) var calls: [[String]] = []

  func record(_ arguments: [String]) {
    calls.append(arguments)
  }
}

struct GitClientLineChangesTests {
  @Test func lineChangesUsesShortstatAndParsesOutput() async throws {
    let store = LineChangesShellCallStore()
    let shell = ShellClient(
      run: { _, arguments, _ in
        await store.record(arguments)
        if arguments.contains("--shortstat") {
          return ShellOutput(
            stdout: " 1 file changed, 12 insertions(+), 3 deletions(-)\n", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let changes = await client.lineChanges(at: URL(fileURLWithPath: "/tmp/repo"))

    #expect(changes?.added == 12)
    #expect(changes?.removed == 3)
    let calls = await store.calls
    #expect(calls.count == 2)
    let diffArgs = try #require(calls.first { $0.contains("--shortstat") })
    #expect(diffArgs.first == "git")
    #expect(diffArgs.contains("diff"))
    #expect(diffArgs.contains("HEAD"))
    #expect(!diffArgs.contains("--numstat"))
    let untrackedArgs = try #require(calls.first { $0.contains("ls-files") })
    #expect(untrackedArgs.contains("--others"))
    #expect(untrackedArgs.contains("--exclude-standard"))
  }

  @Test func lineChangesHandlesMissingDeletions() async {
    let shell = ShellClient(
      run: { _, arguments, _ in
        if arguments.contains("--shortstat") {
          return ShellOutput(stdout: " 1 file changed, 5 insertions(+)\n", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let changes = await client.lineChanges(at: URL(fileURLWithPath: "/tmp/repo"))

    #expect(changes?.added == 5)
    #expect(changes?.removed == 0)
  }

  @Test func lineChangesParsesShortstatLine() async {
    let shell = ShellClient(
      run: { _, arguments, _ in
        if arguments.contains("--shortstat") {
          return ShellOutput(
            stdout: "1 file changed, 10 insertions(+), 4 deletions(-)\n", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let changes = await client.lineChanges(at: URL(fileURLWithPath: "/tmp/repo"))

    #expect(changes?.added == 10)
    #expect(changes?.removed == 4)
  }

  @Test func lineChangesHandlesEmptyOutput() async {
    let shell = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "\n", stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let changes = await client.lineChanges(at: URL(fileURLWithPath: "/tmp/repo"))

    #expect(changes?.added == 0)
    #expect(changes?.removed == 0)
  }

  @Test func lineChangesIncludesUntrackedFileLines() async throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    let gitDirectory = tempRoot.appending(path: ".git")
    try fileManager.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
    let headURL = gitDirectory.appending(path: "HEAD")
    try "ref: refs/heads/main\n".write(to: headURL, atomically: true, encoding: .utf8)

    let untrackedFile = tempRoot.appending(path: "new_file.swift")
    try "line1\nline2\nline3\n".write(to: untrackedFile, atomically: true, encoding: .utf8)

    let shell = ShellClient(
      run: { _, arguments, _ in
        if arguments.contains("--shortstat") {
          return ShellOutput(
            stdout: " 1 file changed, 10 insertions(+), 2 deletions(-)\n", stderr: "", exitCode: 0)
        }
        if arguments.contains("ls-files") {
          return ShellOutput(stdout: "new_file.swift\n", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let changes = await client.lineChanges(at: tempRoot)

    #expect(changes?.added == 13)
    #expect(changes?.removed == 2)
  }

  @Test func lineChangesSkipsBinaryUntrackedFiles() async throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    let gitDirectory = tempRoot.appending(path: ".git")
    try fileManager.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
    let headURL = gitDirectory.appending(path: "HEAD")
    try "ref: refs/heads/main\n".write(to: headURL, atomically: true, encoding: .utf8)

    let binaryFile = tempRoot.appending(path: "image.png")
    var binaryData = Data("PNG\n".utf8)
    binaryData.append(0x00)
    binaryData.append(contentsOf: Data(repeating: 0x0A, count: 100))
    try binaryData.write(to: binaryFile)

    let textFile = tempRoot.appending(path: "readme.txt")
    try "hello\nworld\n".write(to: textFile, atomically: true, encoding: .utf8)

    let shell = ShellClient(
      run: { _, arguments, _ in
        if arguments.contains("--shortstat") {
          return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }
        if arguments.contains("ls-files") {
          return ShellOutput(stdout: "image.png\nreadme.txt\n", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let changes = await client.lineChanges(at: tempRoot)

    #expect(changes?.added == 2)
    #expect(changes?.removed == 0)
  }

  @Test func lineChangesSkipsWhenIndexLocked() async throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    let gitDirectory = tempRoot.appending(path: ".git")
    try fileManager.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
    let headURL = gitDirectory.appending(path: "HEAD")
    try "ref: refs/heads/main\n".write(to: headURL, atomically: true, encoding: .utf8)
    let lockURL = gitDirectory.appending(path: "index.lock")
    try Data().write(to: lockURL)
    let store = LineChangesShellCallStore()
    let shell = ShellClient(
      run: { _, arguments, _ in
        await store.record(arguments)
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let changes = await client.lineChanges(at: tempRoot)

    #expect(changes == nil)
    let calls = await store.calls
    #expect(calls.isEmpty)
  }

  @Test func indexEntryCountReadsGitIndexHeader() throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    let gitDirectory = tempRoot.appending(path: ".git")
    try fileManager.createDirectory(at: gitDirectory, withIntermediateDirectories: true)

    var header = Data()
    header.append(contentsOf: "DIRC".utf8)
    var version = UInt32(2).bigEndian
    header.append(Data(bytes: &version, count: 4))
    var entryCount = UInt32(42_000).bigEndian
    header.append(Data(bytes: &entryCount, count: 4))
    try header.write(to: gitDirectory.appending(path: "index"))

    let count = GitClient.indexEntryCount(at: tempRoot)
    #expect(count == 42_000)
  }

  @Test func indexEntryCountReturnsNilForMissingIndex() {
    let count = GitClient.indexEntryCount(at: URL(fileURLWithPath: "/nonexistent"))
    #expect(count == nil)
  }

  @Test func countLinesInFilesCountsNewlines() throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    try "a\nb\nc\n".write(to: tempRoot.appending(path: "a.txt"), atomically: true, encoding: .utf8)
    try "x\ny\n".write(to: tempRoot.appending(path: "b.txt"), atomically: true, encoding: .utf8)

    let count = GitClient.countLinesInFiles(["a.txt", "b.txt"], relativeTo: tempRoot)
    #expect(count == 5)
  }

  @Test func countLinesInFilesSkipsBinaryFiles() throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    try "text\nfile\n".write(to: tempRoot.appending(path: "ok.txt"), atomically: true, encoding: .utf8)
    var binary = Data("header\n".utf8)
    binary.append(0x00)
    binary.append(contentsOf: Data(repeating: 0x0A, count: 50))
    try binary.write(to: tempRoot.appending(path: "img.bin"))

    let count = GitClient.countLinesInFiles(["ok.txt", "img.bin"], relativeTo: tempRoot)
    #expect(count == 2)
  }

  @Test func countLinesInFilesSkipsMissingFiles() throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    try "a\nb\n".write(to: tempRoot.appending(path: "exists.txt"), atomically: true, encoding: .utf8)

    let count = GitClient.countLinesInFiles(["exists.txt", "gone.txt"], relativeTo: tempRoot)
    #expect(count == 2)
  }
}
