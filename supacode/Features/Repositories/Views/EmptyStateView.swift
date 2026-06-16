import ComposableArchitecture
import SwiftUI

struct EmptyStateView: View {
  let store: StoreOf<RepositoriesFeature>
  @Environment(\.resolvedKeybindings) private var resolvedKeybindings
  @State private var isAddChoicePresented = false

  var body: some View {
    let shortcutDisplay = AppShortcuts.display(
      for: AppShortcuts.CommandID.openRepository, in: resolvedKeybindings)
    ContentUnavailableView {
      Label("Open a repository or folder", systemImage: "folder.badge.plus")
    } description: {
      Text(promptText(shortcutDisplay: shortcutDisplay))
    } actions: {
      Button("Add...") {
        isAddChoicePresented = true
      }
      .modifier(
        KeyboardShortcutModifier(
          shortcut: resolvedKeybindings.keyboardShortcut(for: AppShortcuts.CommandID.openRepository)
        )
      )
      .help(
        AppShortcuts.helpText(
          title: "Add Repository",
          commandID: AppShortcuts.CommandID.openRepository,
          in: resolvedKeybindings
        ))
    }
    .confirmationDialog(
      "Add to Prowl",
      isPresented: $isAddChoicePresented,
      titleVisibility: .visible
    ) {
      Button("Add Local Repository/Folder") {
        store.send(.setOpenPanelPresented(true))
      }
      Button("Add Workspace") {
        store.send(.workspaceCreation(.promptRequested))
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "A local repository or folder opens one project root. "
          + "A workspace creates one shared task folder "
          + "containing multiple repositories for one agent to work across."
      )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func promptText(shortcutDisplay: String?) -> String {
    if let shortcutDisplay {
      return "Press \(shortcutDisplay) or click Add to add one."
    }
    return "Click Add to add one."
  }
}
