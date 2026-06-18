import SwiftUI

/// Rows for the child repositories of an expanded workspace.
/// Reuses `WorktreeRow` for visual parity with git worktree rows (`+N/-M` diff
/// badge, PR tag), while clicking a child focuses its bound terminal tab,
/// creating one rooted at that repository's folder when needed.
struct WorkspaceChildRowsView: View {
  let rows: [WorkspaceChildRowModel]
  let selectedID: String?
  let onSelect: (String) -> Void

  var body: some View {
    ForEach(rows) { row in
      let isSelected = row.id == selectedID
      WorkspaceChildRowButton(row: row, isSelected: isSelected, onSelect: onSelect)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .background {
          if isSelected {
            RoundedRectangle(cornerRadius: 8)
              .fill(Color.accentColor.opacity(0.18))
              .padding(.horizontal, 6)
          }
        }
        .padding(.vertical, 2)
        .id(row.id)
    }
  }
}

private struct WorkspaceChildRowButton: View {
  let row: WorkspaceChildRowModel
  let isSelected: Bool
  let onSelect: (String) -> Void

  var body: some View {
    Button {
      onSelect(row.id)
    } label: {
      content
    }
    .buttonStyle(.plain)
    .help("Focus Terminal in \(row.repositoryName)")
  }

  private var content: some View {
    WorktreeRow(
      name: row.branchName ?? row.repositoryName,
      worktreeName: row.branchName == nil ? "" : row.repositoryName,
      info: row.info,
      iconSystemName: nil,
      showsPullRequestInfo: true,
      isHovered: false,
      isPinned: false,
      isMainWorktree: false,
      isLoading: false,
      taskStatus: nil,
      isRunScriptRunning: false,
      showsNotificationIndicator: false,
      notifications: [],
      onFocusNotification: { _ in },
      shortcutHint: nil,
      showsShortcutHint: false,
      pinAction: nil,
      isSelected: isSelected,
      archiveAction: nil,
      onDiffTap: nil,
      onStopRunScript: nil,
    )
  }
}
