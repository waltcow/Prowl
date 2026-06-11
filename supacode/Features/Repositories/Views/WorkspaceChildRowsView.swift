import SwiftUI

/// Display-only rows for the child repositories of an expanded workspace.
/// Reuses `WorktreeRow` for visual parity with git worktree rows (branch icon,
/// `+N/-M` diff badge, PR tag), but deliberately omits selection, drag, context
/// menu, and tap handling — a workspace has a single root terminal and its
/// children are not independently runnable targets.
struct WorkspaceChildRowsView: View {
  let rows: [WorkspaceChildRowModel]

  var body: some View {
    ForEach(rows) { row in
      WorktreeRow(
        name: row.branchName ?? row.repositoryName,
        worktreeName: row.branchName == nil ? "" : row.repositoryName,
        info: row.info,
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
        isSelected: false,
        archiveAction: nil,
        onDiffTap: nil,
        onStopRunScript: nil,
      )
      .padding(.leading, 14)
      .padding(.trailing, 8)
      .id(row.id)
    }
  }
}
