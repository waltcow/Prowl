import Foundation

struct CanvasFocusRequest: Equatable, Sendable {
  enum Target: Equatable, Sendable {
    case worktree(Worktree.ID)
    case tab(TerminalTabID)
  }

  let id: Int
  let target: Target
}

struct CanvasFocusCandidate: Equatable, Sendable {
  let worktreeID: Worktree.ID
  let tabID: TerminalTabID
}

enum CanvasFocusResolver {
  static func resolve(
    request: CanvasFocusRequest,
    candidates: [CanvasFocusCandidate],
    currentPrimaryTabID: TerminalTabID?
  ) -> TerminalTabID? {
    switch request.target {
    case .tab(let tabID):
      return candidates.contains { $0.tabID == tabID } ? tabID : nil

    case .worktree(let worktreeID):
      let matchingTabIDs = candidates.compactMap { candidate in
        candidate.worktreeID == worktreeID ? candidate.tabID : nil
      }
      guard !matchingTabIDs.isEmpty else { return nil }
      guard let currentPrimaryTabID,
        let currentIndex = matchingTabIDs.firstIndex(of: currentPrimaryTabID)
      else {
        return matchingTabIDs[0]
      }
      return matchingTabIDs[(currentIndex + 1) % matchingTabIDs.count]
    }
  }
}
