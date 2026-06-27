import AppKit
import SwiftUI

struct CloneRepositoryView: View {
  @State private var urlString = ""
  @State private var locationPath = Self.defaultClonePath
  @State private var isCloning = false
  @State private var errorMessage: String?
  @Environment(\.dismiss) private var dismiss
  let onCloned: (URL) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Clone")
          .font(.system(size: 16, weight: .semibold))
        Text("Clone a remote repository into a local directory")
          .font(.system(size: 12.5))
          .foregroundStyle(.secondary)
      }

      Grid(alignment: .leading, verticalSpacing: 12) {
        GridRow {
          Text("URL:")
            .gridColumnAlignment(.trailing)
          TextField("Git Repository URL", text: $urlString)
            .textFieldStyle(.roundedBorder)
        }
        GridRow {
          Text("Location:")
          HStack(spacing: 6) {
            TextField("Clone destination", text: $locationPath)
              .textFieldStyle(.roundedBorder)
            Button {
              pickLocation()
            } label: {
              Image(systemName: "folder")
                .accessibilityHidden(true)
            }
            .accessibilityLabel("Choose clone destination")
            .help("Choose clone destination")
          }
        }
      }

      if let errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(.red)
          .textSelection(.enabled)
      }

      HStack {
        Spacer()
        Button("Cancel") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        Button("Clone") {
          performClone()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!isValidInput || isCloning)
      }
    }
    .padding(24)
    .frame(width: 460)
    .onAppear { prefillFromClipboard() }
    .opacity(isCloning ? 0 : 1)
    .overlay {
      if isCloning {
        VStack(spacing: 8) {
          ProgressView()
          Text("Cloning…")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var isValidInput: Bool {
    !urlString.trimmingCharacters(in: .whitespaces).isEmpty
      && !locationPath.trimmingCharacters(in: .whitespaces).isEmpty
  }

  private func prefillFromClipboard() {
    guard let content = NSPasteboard.general.string(forType: .string) else { return }
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    if Self.isGitURL(trimmed) {
      urlString = trimmed
    }
  }

  private func pickLocation() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    if panel.runModal() == .OK, let url = panel.url {
      locationPath = url.path
    }
  }

  private func performClone() {
    let repoName = Self.extractRepoName(from: urlString)
    let destination = URL(fileURLWithPath: locationPath).appendingPathComponent(repoName, isDirectory: true)
    let url = urlString

    isCloning = true
    errorMessage = nil

    Task {
      let error = await Self.runGitClone(url: url, destination: destination)
      isCloning = false
      if let error {
        errorMessage = error
      } else {
        dismiss()
        onCloned(destination)
      }
    }
  }

  /// Returns `nil` on success, or an error message on failure.
  static func runGitClone(url: String, destination: URL) async -> String? {
    await withCheckedContinuation { continuation in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      process.arguments = ["clone", "--", url, destination.path]
      let errorPipe = Pipe()
      process.standardError = errorPipe
      process.standardOutput = FileHandle.nullDevice

      process.terminationHandler = { proc in
        if proc.terminationStatus == 0 {
          continuation.resume(returning: nil)
        } else {
          let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
          let msg =
            String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Clone failed"
          continuation.resume(returning: msg)
        }
      }

      do {
        try process.run()
      } catch {
        continuation.resume(returning: error.localizedDescription)
      }
    }
  }

  static func isGitURL(_ string: String) -> Bool {
    if string.hasPrefix("https://") || string.hasPrefix("http://") {
      if string.hasSuffix(".git") { return true }
      let hosts = ["github.com", "gitlab.com", "bitbucket.org", "dev.azure.com", "gitee.com"]
      return hosts.contains { string.contains($0) }
    }
    if string.hasPrefix("git@") && string.contains(":") { return true }
    if string.hasPrefix("git://") || string.hasPrefix("ssh://") { return true }
    return false
  }

  static func extractRepoName(from urlString: String) -> String {
    let cleaned = urlString.hasSuffix("/") ? String(urlString.dropLast()) : urlString
    var name: String
    if cleaned.contains(":") && !cleaned.contains("://") {
      name =
        cleaned.components(separatedBy: "/").last
        ?? cleaned.components(separatedBy: ":").last ?? cleaned
    } else {
      name = URL(string: cleaned)?.lastPathComponent ?? cleaned
    }
    if name.hasSuffix(".git") {
      name = String(name.dropLast(4))
    }
    return name.isEmpty ? "repository" : name
  }

  private static var defaultClonePath: String {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let developer = home.appendingPathComponent("Developer")
    if FileManager.default.fileExists(atPath: developer.path) {
      return developer.path
    }
    return home.path
  }
}
