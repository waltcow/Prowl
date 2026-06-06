import Foundation

struct GithubAuthStatus: Equatable, Sendable {
  let username: String
  let host: String
}

struct GithubAuthStatusResponse: Sendable {
  let hosts: [String: [GithubAuthAccount]]

  struct GithubAuthAccount: Sendable {
    let active: Bool
    let login: String
  }
}

extension GithubAuthStatusResponse: Decodable {
  private enum CodingKeys: String, CodingKey {
    case hosts
  }

  nonisolated init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.hosts = try container.decode([String: [GithubAuthAccount]].self, forKey: .hosts)
  }
}

extension GithubAuthStatusResponse.GithubAuthAccount: Decodable {
  private enum CodingKeys: String, CodingKey {
    case active
    case login
  }

  nonisolated init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.active = try container.decode(Bool.self, forKey: .active)
    self.login = try container.decode(String.self, forKey: .login)
  }
}

nonisolated struct RepoKey: Hashable, Sendable {
  let owner: String
  let repo: String
}

nonisolated struct CrossRepoPullRequestRequest: Sendable, Hashable {
  let owner: String
  let repo: String
  let branches: [String]

  var key: RepoKey {
    RepoKey(owner: owner, repo: repo)
  }
}

nonisolated struct CrossRepoPullRequestResult: Sendable {
  let successByRepo: [RepoKey: [String: GithubPullRequest]]
  let failedRepos: [RepoKey: GithubCLIError]

  init(
    successByRepo: [RepoKey: [String: GithubPullRequest]] = [:],
    failedRepos: [RepoKey: GithubCLIError] = [:]
  ) {
    self.successByRepo = successByRepo
    self.failedRepos = failedRepos
  }
}

struct GithubPullRequestsRequest: Sendable {
  let host: String
  let owner: String
  let repo: String
}

nonisolated struct GithubRepoViewRemoteInfoResponse: Decodable, Sendable {
  let owner: Owner
  let name: String
  let url: String

  nonisolated var remoteInfo: GithubRemoteInfo? {
    guard let host = URL(string: url)?.host else {
      return nil
    }
    return GithubRemoteInfo(host: host, owner: owner.login, repo: name)
  }

  nonisolated struct Owner: Decodable, Sendable {
    let login: String
  }
}
