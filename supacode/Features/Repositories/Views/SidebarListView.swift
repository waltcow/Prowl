import ComposableArchitecture
import Sharing
import SwiftUI

// Uses LazyVStack rather than List for repository drag precision; keyboard
// worktree navigation goes through Cmd+Ctrl+↑/↓ (`selectNextWorktree`).
struct SidebarListView: View {
  enum RepositoryListHeaderAction: Equatable {
    case expandAll
    case collapseAll

    var title: String {
      switch self {
      case .expandAll:
        return "Expand All"
      case .collapseAll:
        return "Collapse All"
      }
    }

    var systemImageName: String {
      "chevron.right"
    }

    var rotation: Angle {
      switch self {
      case .expandAll:
        return .zero
      case .collapseAll:
        return .degrees(90)
      }
    }
  }

  @Bindable var store: StoreOf<RepositoriesFeature>
  @Binding var expandedRepoIDs: Set<Repository.ID>
  @Binding var sidebarSelections: Set<SidebarSelection>
  let terminalManager: WorktreeTerminalManager
  @State private var isDragActive = false
  @State private var draggingRepositoryID: Repository.ID?
  @State private var targetedRepositoryDropDestination: Int?
  @State private var sidebarHeight = 0.0
  @State private var sidebarFooterHeight = 0.0
  @State private var resizingPanelHeight: Double?
  @Namespace private var topSegmentNamespace
  @Environment(\.resolvedKeybindings) private var resolvedKeybindings
  @Shared(.repositoryAppearances) private var repositoryAppearances

  var body: some View {
    let state = store.state
    let hotkeyRows = state.orderedWorktreeRows(includingRepositoryIDs: expandedRepoIDs)
    let presentation = state.sidebarPresentation(expandedRepositoryIDs: expandedRepoIDs)
    let expandableRepositoryIDs = Self.expandableRepositoryIDs(in: state.repositories)
    let repositoryListHeaderAction = Self.repositoryListHeaderAction(
      expandedRepoIDs: expandedRepoIDs,
      expandableRepositoryIDs: expandableRepositoryIDs
    )
    let repositoryItems = presentation.items.filter(\.isRepositoryOrderItem)
    let selectedWorktreeIDs = Self.selectedWorktreeIDs(in: state)
    let selectedSurfaceID = state.selectedWorktreeID.flatMap { worktreeID in
      terminalManager.stateIfExists(for: worktreeID)?.activeSurfaceID
    }
    let pendingSidebarReveal = state.pendingSidebarReveal

    let maximumPanelHeight =
      sidebarHeight > 0
      ? ActiveAgentsFeature.maximumPanelHeight(forContainerHeight: sidebarHeight)
      : ActiveAgentsFeature.maximumPanelHeight
    let agentWorktreeMetadata = Self.activeAgentWorktreeMetadata(
      repositories: state.repositories,
      customTitles: state.repositoryCustomTitles,
      repositoryAppearances: repositoryAppearances
    )
    let panelHeight = min(resizingPanelHeight ?? state.activeAgents.panelHeight, maximumPanelHeight)
    let panelOffset = state.activeAgents.isPanelHidden ? panelHeight : 0
    let activeAgentsPanelTopGap = 4.0
    let listBottomPadding = state.activeAgents.isPanelHidden ? 0 : panelHeight + activeAgentsPanelTopGap

    ScrollViewReader { scrollProxy in
      ScrollView {
        LazyVStack(spacing: 0) {
          if repositoryItems.isEmpty {
            emptyRepositoryHint()
          } else {
            repositoryListHeader(
              action: repositoryListHeaderAction,
              expandableRepositoryIDs: expandableRepositoryIDs
            )
          }
          ForEach(Array(repositoryItems.enumerated()), id: \.element.id) { index, item in
            repositoryItemView(
              item,
              index: index,
              repositoryOrderIDs: presentation.repositoryOrderIDs,
              hotkeyRows: hotkeyRows,
              selectedWorktreeIDs: selectedWorktreeIDs
            )
          }
        }
        .padding(.vertical, 2)
        .padding(.bottom, listBottomPadding)
      }
      .scrollIndicators(.never)
      .frame(minWidth: 220)
      .clipped()
      .onGeometryChange(for: Double.self) { proxy in
        Double(proxy.size.height)
      } action: { newHeight in
        sidebarHeight = newHeight
      }
      .onDragSessionUpdated { session in
        if case .ended = session.phase {
          endSidebarDrag()
          return
        }
        if case .dataTransferCompleted = session.phase {
          endSidebarDrag()
        }
      }
      .safeAreaInset(edge: .top, spacing: 0) {
        topSegmentBar
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        SidebarFooterView(store: store)
          .onGeometryChange(for: Double.self) { proxy in
            Double(proxy.size.height)
          } action: { newHeight in
            sidebarFooterHeight = newHeight
          }
          .padding(.vertical, 4)
      }
      .overlay(alignment: .bottom) {
        ActiveAgentsPanel(
          store: store.scope(state: \.activeAgents, action: \.activeAgents),
          repositoryNamesByWorktreeID: agentWorktreeMetadata.repositoryNamesByWorktreeID,
          branchNamesByWorktreeID: agentWorktreeMetadata.branchNamesByWorktreeID,
          repositoryColorsByWorktreeID: agentWorktreeMetadata.repositoryColorsByWorktreeID,
          selectedSurfaceID: selectedSurfaceID,
          height: panelHeight,
          maximumHeight: maximumPanelHeight,
          onHeightChanged: { height in
            resizingPanelHeight = height
          },
          onHeightChangeEnded: { height in
            resizingPanelHeight = nil
            store.send(.activeAgents(.panelHeightChanged(height)))
          }
        )
        .padding(6)
        .frame(height: panelHeight)
        .offset(y: panelOffset)
        .clipped()
        .padding(.bottom, sidebarFooterHeight)
        .allowsHitTesting(!state.activeAgents.isPanelHidden)
        .animation(.easeOut(duration: 0.18), value: state.activeAgents.isPanelHidden)
      }
      .dropDestination(for: URL.self) { urls, _ in
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return false }
        store.send(.repositoryManagement(.openRepositories(fileURLs)))
        return true
      }
      .onAppear {
        resetSidebarDrag()
      }
      .task(id: pendingSidebarReveal?.id) {
        await revealPendingSidebarWorktree(pendingSidebarReveal, with: scrollProxy)
      }
      .toolbar {
        ToolbarItem(placement: .automatic) {
          Button {
            store.send(.setOpenPanelPresented(true))
          } label: {
            Label("Add Repository", systemImage: "folder.badge.plus")
          }
          .help("Add Repository")
        }
      }
    }  // ScrollViewReader
  }

  // Fixed, opaque top bar (Xcode-navigator style): stays put while the list
  // scrolls underneath, so it neither bounces with the scroll nor lets repo
  // rows show through. Custom segmented control because the system .segmented
  // Picker only renders bare icon/text and ignores option layout, so it can't
  // be widened to fill; equal-width buttons inside a glass capsule track give
  // the macOS 26 look while truly filling the width.
  private var topSegmentBar: some View {
    HStack(spacing: 4) {
      topSegmentButton(.tabbed, systemImage: "checklist.unchecked", title: "Default")
      topSegmentButton(
        .canvas,
        systemImage: "square.grid.2x2",
        title: "Canvas",
        shortcutCommandID: AppShortcuts.CommandID.toggleCanvas
      )
      topSegmentButton(
        .shelf,
        systemImage: "distribute.horizontal.fill",
        title: "Shelf",
        shortcutCommandID: AppShortcuts.CommandID.toggleShelf
      )
    }
    .background(.thinMaterial, in: Capsule())
    .padding(.horizontal, 8)
    .padding(.vertical, 2)
  }

  private func topSegmentButton(
    _ segment: TopSegment,
    systemImage: String,
    title: String,
    shortcutCommandID: String? = nil
  ) -> some View {
    let isSelected = store.topSegment == segment
    let helpText =
      shortcutCommandID.map {
        AppShortcuts.helpText(title: title, commandID: $0, in: resolvedKeybindings)
      } ?? title
    return Button {
      store.send(.setTopSegment(segment))
    } label: {
      Image(systemName: systemImage)
        .accessibilityHidden(true)
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
        .background {
          if isSelected {
            Capsule()
              .fill(Color.accentColor)
              .matchedGeometryEffect(id: "topSegmentPill", in: topSegmentNamespace)
          }
        }
        .contentShape(.capsule)
    }
    .buttonStyle(.plain)
    .help(helpText)
    .accessibilityLabel(Text(title))
  }

  private func focusTerminalAfterSidebarSelection(worktreeID: Worktree.ID?) {
    guard let worktreeID else { return }
    Task { @MainActor [terminalManager] in
      for _ in 0..<4 {
        await Task.yield()
        if let terminalState = terminalManager.stateIfExists(for: worktreeID) {
          terminalState.focusSelectedTab()
          return
        }
      }
    }
  }

  private func repositoryListHeader(
    action: RepositoryListHeaderAction,
    expandableRepositoryIDs: Set<Repository.ID>
  ) -> some View {
    HStack(spacing: 4) {
      Text("Repositories")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
      if !expandableRepositoryIDs.isEmpty {
        Button {
          withAnimation(.easeOut(duration: 0.2)) {
            switch action {
            case .expandAll:
              expandedRepoIDs.formUnion(expandableRepositoryIDs)
            case .collapseAll:
              expandedRepoIDs.subtract(expandableRepositoryIDs)
            }
          }
        } label: {
          Label(action.title, systemImage: action.systemImageName)
            .labelStyle(.iconOnly)
            .frame(width: 20, height: 20)
            .rotationEffect(action.rotation)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(action.title)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 26, alignment: .center)
    .padding(.leading, 12)
    .padding(.trailing, 7)
    .padding(.top, 2)
    .padding(.bottom, 4)
  }

  private func emptyRepositoryHint() -> some View {
    HStack(spacing: 6) {
      Spacer(minLength: 0)
      Text("Add your first repository")
        .font(.caption)
        .foregroundStyle(.secondary)
      Image(systemName: "arrow.turn.right.up")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .symbolEffect(.pulse, options: .repeating)
        .accessibilityHidden(true)
    }
    .padding(.leading, 12)
    .padding(.trailing, 14)
    .padding(.top, 2)
    .padding(.bottom, 6)
  }

  @ViewBuilder
  private func repositoryItemView(
    _ item: SidebarItem,
    index: Int,
    repositoryOrderIDs: [Repository.ID],
    hotkeyRows: [WorktreeRowModel],
    selectedWorktreeIDs: Set<Worktree.ID>
  ) -> some View {
    Group {
      switch item {
      case .repository(let model):
        if let repository = store.state.repositories[id: model.repositoryID] {
          RepositorySectionView(
            repository: repository,
            hasTopSpacing: index > 0,
            isDragActive: isDragActive,
            hotkeyRows: hotkeyRows,
            selectedWorktreeIDs: selectedWorktreeIDs,
            expandedRepoIDs: $expandedRepoIDs,
            store: store,
            terminalManager: terminalManager,
            onRepositorySelected: {
              selectRepository(repository)
            }
          )
          .draggableRepository(
            id: model.repositoryID,
            isEnabled: !model.isRemoving,
            beginDrag: {
              beginSidebarDrag(repositoryID: model.repositoryID)
            }
          )
        }

      case .failedRepository(let model):
        FailedRepositoryRow(
          name: model.name,
          path: model.path,
          showFailure: {
            let message = "\(model.path)\n\n\(model.failureMessage)"
            store.send(.presentAlert(title: "Unable to load \(model.name)", message: message))
          },
          removeRepository: {
            store.send(.repositoryManagement(.removeFailedRepository(model.id)))
          }
        )
        .padding(.horizontal, 12)
        .overlay(alignment: .top) {
          if index > 0 {
            Rectangle()
              .fill(.secondary)
              .frame(height: 1)
              .frame(maxWidth: .infinity)
              .accessibilityHidden(true)
          }
        }
        .draggableRepository(
          id: model.id,
          isEnabled: model.isReorderable,
          beginDrag: {
            beginSidebarDrag(repositoryID: model.id)
          }
        )

      case .listHeader, .archivedWorktrees:
        EmptyView()
      }
    }
    .repositoryDropTarget(
      index: index,
      repositoryOrderIDs: repositoryOrderIDs,
      isEnabled: isDragActive,
      targetedDestination: $targetedRepositoryDropDestination,
      actions: SidebarDropTargetActions(
        draggedItemID: draggingRepositoryID,
        onDrop: { offsets, destination in
          withAnimation(.easeOut(duration: 0.2)) {
            _ = store.send(.worktreeOrdering(.repositoriesMoved(offsets, destination)))
          }
        },
        onDragEnded: endSidebarDrag
      )
    )
  }

  private func beginSidebarDrag(repositoryID: Repository.ID) {
    guard !isDragActive else { return }
    draggingRepositoryID = repositoryID
    isDragActive = true
    store.send(.worktreeOrdering(.setSidebarDragActive(true)))
  }

  private func endSidebarDrag() {
    targetedRepositoryDropDestination = nil
    draggingRepositoryID = nil
    isDragActive = false
    store.send(.worktreeOrdering(.setSidebarDragActive(false)))
  }

  private func resetSidebarDrag() {
    targetedRepositoryDropDestination = nil
    draggingRepositoryID = nil
    isDragActive = false
    store.send(.worktreeOrdering(.setSidebarDragActive(false)))
  }

  private func selectRepository(_ repository: Repository) {
    if repository.capabilities.supportsWorktrees {
      withAnimation(.easeOut(duration: 0.2)) {
        if expandedRepoIDs.contains(repository.id) {
          expandedRepoIDs.remove(repository.id)
        } else {
          expandedRepoIDs.insert(repository.id)
        }
      }
      sidebarSelections = []
    } else {
      sidebarSelections = [.repository(repository.id)]
      store.send(.selectRepository(repository.id))
      focusTerminalAfterSidebarSelection(worktreeID: store.state.selectedTerminalWorktree?.id)
    }
  }

  @MainActor
  private func revealPendingSidebarWorktree(
    _ pendingSidebarReveal: PendingSidebarReveal?,
    with scrollProxy: ScrollViewProxy
  ) async {
    guard let pendingSidebarReveal else { return }
    // Give SwiftUI time to materialize newly expanded section rows before scrolling.
    await Task.yield()
    await Task.yield()
    withAnimation(.easeOut(duration: 0.2)) {
      scrollProxy.scrollTo(SidebarScrollID.worktree(pendingSidebarReveal.worktreeID), anchor: .center)
    }
    store.send(.consumePendingSidebarReveal(pendingSidebarReveal.id))
  }

  static func expandableRepositoryIDs<Repositories: Sequence>(
    in repositories: Repositories
  ) -> Set<Repository.ID> where Repositories.Element == Repository {
    Set(
      repositories
        .filter(\.capabilities.supportsWorktrees)
        .map(\.id)
    )
  }

  static func repositoryListHeaderAction(
    expandedRepoIDs: Set<Repository.ID>,
    expandableRepositoryIDs: Set<Repository.ID>
  ) -> RepositoryListHeaderAction {
    !expandedRepoIDs.isDisjoint(with: expandableRepositoryIDs)
      ? .collapseAll
      : .expandAll
  }

  static func selectedWorktreeIDs(in state: RepositoriesFeature.State) -> Set<Worktree.ID> {
    var selectedWorktreeIDs = state.sidebarSelectedWorktreeIDs
    if let selectedWorktreeID = state.selectedWorktreeID {
      selectedWorktreeIDs.insert(selectedWorktreeID)
    }
    return selectedWorktreeIDs
  }

  static func activeAgentWorktreeMetadata(
    repositories: IdentifiedArrayOf<Repository>,
    customTitles: [Repository.ID: String],
    repositoryAppearances: [Repository.ID: RepositoryAppearance] = [:]
  ) -> ActiveAgentWorktreeMetadata {
    var repositoryNamesByWorktreeID: [Worktree.ID: String] = [:]
    var branchNamesByWorktreeID: [Worktree.ID: String] = [:]
    var repositoryColorsByWorktreeID: [Worktree.ID: RepositoryColorChoice] = [:]

    for repository in repositories {
      let repositoryName = customTitles[repository.id] ?? repository.name
      let repositoryColor = repositoryAppearances[repository.id]?.color
      if repository.capabilities.supportsRunnableFolderActions && !repository.capabilities.supportsWorktrees {
        repositoryNamesByWorktreeID[repository.id] = repositoryName
        branchNamesByWorktreeID[repository.id] = repository.name
        if let repositoryColor {
          repositoryColorsByWorktreeID[repository.id] = repositoryColor
        }
      }
      for worktree in repository.worktrees {
        repositoryNamesByWorktreeID[worktree.id] = repositoryName
        branchNamesByWorktreeID[worktree.id] = worktree.name
        if let repositoryColor {
          repositoryColorsByWorktreeID[worktree.id] = repositoryColor
        }
      }
    }

    return ActiveAgentWorktreeMetadata(
      repositoryNamesByWorktreeID: repositoryNamesByWorktreeID,
      branchNamesByWorktreeID: branchNamesByWorktreeID,
      repositoryColorsByWorktreeID: repositoryColorsByWorktreeID
    )
  }
}

struct ActiveAgentWorktreeMetadata: Equatable {
  let repositoryNamesByWorktreeID: [Worktree.ID: String]
  let branchNamesByWorktreeID: [Worktree.ID: String]
  let repositoryColorsByWorktreeID: [Worktree.ID: RepositoryColorChoice]
}

extension SidebarItem {
  fileprivate var isRepositoryOrderItem: Bool {
    repositoryOrderID != nil
  }
}

// MARK: - Previews

#if DEBUG
  @MainActor
  private struct SidebarLayoutPreview: View {
    @State private var expandedRepoIDs: Set<Repository.ID>
    @State private var sidebarSelections: Set<SidebarSelection> = []
    private let store: StoreOf<RepositoriesFeature>
    private let terminalManager: WorktreeTerminalManager = .preview

    init() {
      let state = Self.mockState
      _expandedRepoIDs = State(initialValue: Set(state.repositories.map(\.id)))
      store = Store(initialState: state) { EmptyReducer() }
    }

    var body: some View {
      SidebarListView(
        store: store,
        expandedRepoIDs: $expandedRepoIDs,
        sidebarSelections: $sidebarSelections,
        terminalManager: terminalManager
      )
      .environment(CommandKeyObserver())
      .frame(width: 320, height: 500)
    }

    private static var mockState: RepositoriesFeature.State {
      let repo1Root = URL(fileURLWithPath: "/tmp/supacode")
      let repo1Worktrees: IdentifiedArrayOf<Worktree> = [
        Worktree(
          id: repo1Root.path, name: "main", detail: ".",
          workingDirectory: repo1Root, repositoryRootURL: repo1Root
        ),
        Worktree(
          id: "/tmp/wt/sidebar", name: "feature/sidebar-redesign", detail: "/tmp/wt/sidebar",
          workingDirectory: URL(fileURLWithPath: "/tmp/wt/sidebar"), repositoryRootURL: repo1Root
        ),
        Worktree(
          id: "/tmp/wt/auth", name: "feature/auth", detail: "/tmp/wt/auth",
          workingDirectory: URL(fileURLWithPath: "/tmp/wt/auth"), repositoryRootURL: repo1Root
        ),
        Worktree(
          id: "/tmp/wt/crash", name: "fix/crash", detail: "/tmp/wt/crash",
          workingDirectory: URL(fileURLWithPath: "/tmp/wt/crash"), repositoryRootURL: repo1Root
        ),
      ]
      let repo1 = Repository(
        id: repo1Root.path, rootURL: repo1Root, name: "supacode", worktrees: repo1Worktrees
      )

      let repo2Root = URL(fileURLWithPath: "/tmp/ghostty")
      let repo2Worktrees: IdentifiedArrayOf<Worktree> = [
        Worktree(
          id: repo2Root.path, name: "main", detail: ".",
          workingDirectory: repo2Root, repositoryRootURL: repo2Root
        ),
        Worktree(
          id: "/tmp/wt/renderer", name: "feature/renderer", detail: "/tmp/wt/renderer",
          workingDirectory: URL(fileURLWithPath: "/tmp/wt/renderer"), repositoryRootURL: repo2Root
        ),
      ]
      let repo2 = Repository(
        id: repo2Root.path, rootURL: repo2Root, name: "ghostty", worktrees: repo2Worktrees
      )

      var state = RepositoriesFeature.State()
      state.repositories = [repo1, repo2]
      state.pinnedWorktreeIDs = ["/tmp/wt/auth"]
      state.worktreeInfoByID = [
        "/tmp/wt/sidebar": WorktreeInfoEntry(addedLines: 120, removedLines: 45, pullRequest: nil)
      ]
      return state
    }
  }

  #Preview("Sidebar Layout") {
    SidebarLayoutPreview()
  }
#endif
