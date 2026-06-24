import AppKit
import Testing

@testable import supacode

@MainActor
struct SplitTreeTests {
  @Test func activeSurfaceTracksClickAndGotoSplitPaths() throws {
    let state = makeWorktreeTerminalState()
    let tabId = try #require(state.createTab())
    let firstID = try #require(state.focusedSurfaceId(in: tabId))
    let first = try #require(state.surfaceView(for: firstID))

    #expect(state.performSplitAction(.newSplit(direction: .right), for: firstID))
    let secondID = try #require(state.focusedSurfaceId(in: tabId))
    let second = try #require(state.surfaceView(for: secondID))

    var emissions: [UUID] = []
    state.onFocusChanged = { emissions.append($0) }

    #expect(state.activeSurfaceID(for: tabId) == second.id)

    first.onFocusChange?(true)
    #expect(state.activeSurfaceID(for: tabId) == first.id)

    first.onFocusChange?(true)
    #expect(state.activeSurfaceID(for: tabId) == first.id)

    #expect(state.performSplitAction(.gotoSplit(direction: .next), for: first.id))
    #expect(state.activeSurfaceID(for: tabId) == second.id)

    #expect(state.focusSurface(id: second.id))
    #expect(state.activeSurfaceID(for: tabId) == second.id)

    second.onFocusChange?(false)
    #expect(state.activeSurfaceID(for: tabId) == second.id)

    #expect(emissions == [first.id, second.id])
  }

  @Test func focusTargetAfterClosingUsesNextForLeftmostLeaf() throws {
    let first = SplitTreeTestView()
    let second = SplitTreeTestView()
    let third = SplitTreeTestView()

    let tree = try SplitTree(view: first)
      .inserting(view: second, at: first, direction: .right)
      .inserting(view: third, at: second, direction: .right)

    let node = try #require(tree.find(id: first.id))
    #expect(tree.focusTargetAfterClosing(node) === second)
  }

  @Test func focusTargetAfterClosingUsesPreviousForNonLeftmostLeaf() throws {
    let first = SplitTreeTestView()
    let second = SplitTreeTestView()
    let third = SplitTreeTestView()

    let tree = try SplitTree(view: first)
      .inserting(view: second, at: first, direction: .right)
      .inserting(view: third, at: second, direction: .right)

    let node = try #require(tree.find(id: third.id))
    #expect(tree.focusTargetAfterClosing(node) === second)
  }

  @Test func visibleLeavesOnlyReturnZoomedPane() throws {
    let first = SplitTreeTestView()
    let second = SplitTreeTestView()

    let tree = try SplitTree(view: first)
      .inserting(view: second, at: first, direction: .right)

    let zoomed = tree.settingZoomed(tree.find(id: second.id))
    let visibleLeaves = zoomed.visibleLeaves()

    #expect(visibleLeaves.count == 1)
    #expect(visibleLeaves.first === second)
  }

  private func makeWorktreeTerminalState() -> WorktreeTerminalState {
    WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: Worktree(
        id: "/tmp/repo/wt-1",
        name: "wt-1",
        detail: "",
        workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
        repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
      )
    )
  }
}

private final class SplitTreeTestView: NSView, Identifiable {
  let id = UUID()
}
