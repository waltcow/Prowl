import AppKit
import ComposableArchitecture
import SwiftUI

struct ActiveAgentsPanel: View {
  @Bindable var store: StoreOf<ActiveAgentsFeature>
  let repositoryNamesByWorktreeID: [Worktree.ID: String]
  let branchNamesByWorktreeID: [Worktree.ID: String]
  let repositoryColorsByWorktreeID: [Worktree.ID: RepositoryColorChoice]
  let selectedSurfaceID: UUID?
  /// Merged "⌥⌃↑↓" hint shown while Cmd is held; `nil` hides it (bindings customized
  /// or Cmd not held). Resolved by the parent so the panel stays presentational.
  let navigationShortcutHint: String?
  let height: Double
  let maximumHeight: Double
  let onHeightChanged: (Double) -> Void
  let onHeightChangeEnded: (Double) -> Void
  @State private var dragStartHeight: Double?
  @State private var dragIndicatorPillOpacity: CGFloat = 0.4

  var body: some View {
    VStack(spacing: 0) {
      resizeHandle
      HStack {
        Text("Active Agents")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        if let navigationShortcutHint, !store.entries.isEmpty {
          ShortcutHintView(text: navigationShortcutHint, color: .secondary)
            .transition(.opacity)
        }
      }
      .padding(.horizontal, 12)
      .padding(.top, 8)
      .padding(.bottom, 4)
      .animation(.easeInOut(duration: 0.15), value: navigationShortcutHint)

      if store.entries.isEmpty {
        Spacer(minLength: 0)
        Text("New agents will appear here")
          .font(.callout)
          .foregroundStyle(.secondary)
          // Nudge up slightly off dead-center for better visual balance.
          .offset(y: -8)
        Spacer(minLength: 0)
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(store.entries) { entry in
              Button {
                store.send(.entryTapped(entry.id))
              } label: {
                ActiveAgentRow(
                  entry: entry,
                  repositoryName: repositoryName(for: entry),
                  branchName: branchName(for: entry),
                  repositoryColor: repositoryColor(for: entry),
                  isDimmed: isDimmed(entry)
                )
              }
              .buttonStyle(.plain)
              .help(helpText(for: entry))
            }
          }
        }
        .scrollIndicators(.never)
      }
    }
    .background {
      panelBackgroundShape
        .fill(.thinMaterial)
    }
    .clipShape(panelBackgroundShape)
  }

  private var resizeHandle: some View {
    Rectangle()
      .fill(.clear)
      .frame(height: 1)
      .frame(maxWidth: .infinity)
      .overlay(alignment: .top) {
        Capsule()
          .fill(.separator.opacity(dragIndicatorPillOpacity))
          .frame(width: 32, height: 4)
          .padding(.vertical, 4)
      }
      .overlay {
        Rectangle()
          .fill(.clear)
          .frame(height: 8)
          .contentShape(.rect)
      }
      .gesture(
        DragGesture(coordinateSpace: .global)
          .onChanged { value in
            let start = dragStartHeight ?? height
            dragStartHeight = start
            onHeightChanged(clampedHeight(start - value.translation.height))
            dragIndicatorPillOpacity = 0.8
          }
          .onEnded { value in
            let start = dragStartHeight ?? height
            let height = clampedHeight(start - value.translation.height)
            dragStartHeight = nil
            onHeightChangeEnded(height)
            dragIndicatorPillOpacity = 0.4
          }
      )
      .onHover { hovering in
        if hovering {
          NSCursor.resizeUpDown.set()
        } else {
          NSCursor.arrow.set()
        }
      }
  }

  private func clampedHeight(_ height: Double) -> Double {
    min(maximumHeight, max(ActiveAgentsFeature.minimumPanelHeight, height))
  }

  private func repositoryName(for entry: ActiveAgentEntry) -> String {
    repositoryNamesByWorktreeID[entry.worktreeID] ?? entry.worktreeName
  }

  private func branchName(for entry: ActiveAgentEntry) -> String {
    branchNamesByWorktreeID[entry.worktreeID] ?? entry.worktreeName
  }

  private func repositoryColor(for entry: ActiveAgentEntry) -> RepositoryColorChoice? {
    repositoryColorsByWorktreeID[entry.worktreeID]
  }

  private func isDimmed(_ entry: ActiveAgentEntry) -> Bool {
    // Prefer the reducer-tracked focused surface so keyboard navigation highlights
    // the target immediately. `selectedSurfaceID` is derived from the selected
    // worktree's active surface and only catches up once the async `focusSurface`
    // completes, which would otherwise flash that worktree's previous agent for a
    // frame when navigation wraps across worktrees. Falls back to it before the
    // first focus is recorded.
    if let activeSurfaceID = store.focusedSurfaceID ?? selectedSurfaceID {
      return entry.surfaceID != activeSurfaceID
    }
    return false
  }

  private func helpText(for entry: ActiveAgentEntry) -> String {
    let trimmed = entry.tabTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Untitled tab" : trimmed
  }

  private var panelBackgroundShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 14)
  }
}
