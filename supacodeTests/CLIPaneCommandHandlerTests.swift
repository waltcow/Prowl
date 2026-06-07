import Foundation
import Testing

@testable import supacode

@MainActor
struct CLIPaneCommandHandlerTests {
  @Test func closeResolvesTargetAndClosesPane() async throws {
    let target = makeTarget(tabID: "tab-1", paneID: "pane-to-close")
    var closedTarget: TabResolvedTarget?

    let handler = PaneCommandHandler(
      resolveProvider: { selector in
        #expect(selector == .pane("pane-to-close"))
        return .success(target)
      },
      closePane: { target in
        closedTarget = target
        return true
      }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(
        output: .json,
        command: .pane(PaneInput(action: .close, selector: .pane("pane-to-close")))
      )
    )

    #expect(response.ok == true)
    #expect(closedTarget == target)
    let data = try #require(response.data)
    let payload = try data.decode(as: PaneCommandPayload.self)
    #expect(payload.action == .close)
    #expect(payload.target.pane.id == "pane-to-close")
  }

  @Test func closeReturnsFailureWhenCloseActionFails() async {
    let handler = PaneCommandHandler(
      resolveProvider: { _ in .success(makeTarget()) },
      closePane: { _ in false }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(
        output: .json,
        command: .pane(PaneInput(action: .close, selector: .none))
      )
    )

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.paneFailed)
  }

  private func makeTarget(
    worktreeID: String = "App:/Projects/App",
    worktreeName: String = "App",
    worktreePath: String = "/Projects/App",
    worktreeRootPath: String = "/Projects/App",
    worktreeKind: String = "git",
    tabID: String = "tab-1",
    tabTitle: String = "App 1",
    tabSelected: Bool = true,
    paneID: String = "pane-1",
    paneTitle: String = "zsh",
    paneCWD: String? = "/Projects/App",
    paneFocused: Bool = true
  ) -> TabResolvedTarget {
    TabResolvedTarget(
      worktreeID: worktreeID,
      worktreeName: worktreeName,
      worktreePath: worktreePath,
      worktreeRootPath: worktreeRootPath,
      worktreeKind: worktreeKind,
      tabID: tabID,
      tabTitle: tabTitle,
      tabSelected: tabSelected,
      paneID: paneID,
      paneTitle: paneTitle,
      paneCWD: paneCWD,
      paneFocused: paneFocused
    )
  }
}
