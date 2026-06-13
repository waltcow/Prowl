import Foundation
import Testing

@testable import supacode

struct WorktreeProjectKindTests {
  @Test(arguments: [
    (["App.xcodeproj/"], WorktreeProjectKind.apple),
    (["App.xcworkspace/"], WorktreeProjectKind.apple),
    (["Package.swift"], WorktreeProjectKind.apple),
    (["Project.swift"], WorktreeProjectKind.apple),
    (["settings.gradle"], WorktreeProjectKind.android),
    (["settings.gradle.kts"], WorktreeProjectKind.android),
    (["build.gradle.kts"], WorktreeProjectKind.android),
    (["gradlew"], WorktreeProjectKind.android),
    (["App.sln"], WorktreeProjectKind.dotnet),
    (["App.csproj"], WorktreeProjectKind.dotnet),
    (["pom.xml"], WorktreeProjectKind.java),
    (["go.mod"], WorktreeProjectKind.golang),
    (["Cargo.toml"], WorktreeProjectKind.rust),
    (["CMakeLists.txt"], WorktreeProjectKind.cpp),
    (["composer.json"], WorktreeProjectKind.php),
    (["Gemfile"], WorktreeProjectKind.ruby),
    (["pyproject.toml"], WorktreeProjectKind.python),
    (["requirements.txt"], WorktreeProjectKind.python),
    (["package.json"], WorktreeProjectKind.web),
  ])
  func detectsKindFromMarker(entries: [String], expected: WorktreeProjectKind) throws {
    try withTemporaryProjectDirectory(entries: entries) { directory in
      #expect(WorktreeProjectKind.detect(at: directory) == expected)
    }
  }

  @Test(arguments: [
    (["App.xcodeproj/", "package.json"], WorktreeProjectKind.apple),
    (["Package.swift", "package.json"], WorktreeProjectKind.apple),
    (["gradlew", "package.json"], WorktreeProjectKind.android),
    (["Cargo.toml", "package.json"], WorktreeProjectKind.rust),
    (["go.mod", "CMakeLists.txt"], WorktreeProjectKind.golang),
    (["composer.json", "package.json"], WorktreeProjectKind.php),
  ])
  func specificMarkersWinOverGenericOnes(entries: [String], expected: WorktreeProjectKind) throws {
    try withTemporaryProjectDirectory(entries: entries) { directory in
      #expect(WorktreeProjectKind.detect(at: directory) == expected)
    }
  }

  @Test func returnsNilWithoutMarkers() throws {
    try withTemporaryProjectDirectory(entries: ["README.md", "src/"]) { directory in
      #expect(WorktreeProjectKind.detect(at: directory) == nil)
    }
  }

  @Test func returnsNilForMissingDirectory() {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "missing-\(UUID().uuidString)")
    #expect(WorktreeProjectKind.detect(at: directory) == nil)
  }
}
