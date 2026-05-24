import ComposableArchitecture
import SwiftUI

struct EmptyStateView: View {
  let store: StoreOf<RepositoriesFeature>
  @Environment(\.resolvedKeybindings) private var resolvedKeybindings

  var body: some View {
    let shortcutDisplay = AppShortcuts.display(for: AppShortcuts.CommandID.openRepository, in: resolvedKeybindings)
    ContentUnavailableView {
      Label("Open a repository or folder", systemImage: "folder.badge.plus")
    } description: {
      Text(promptText(shortcutDisplay: shortcutDisplay))
    } actions: {
      Button("Add Repository...") {
        store.send(.setOpenPanelPresented(true))
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
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func promptText(shortcutDisplay: String?) -> String {
    if let shortcutDisplay {
      return "Press \(shortcutDisplay) or click Add Repository to add one."
    }
    return "Click Add Repository to add one."
  }
}
