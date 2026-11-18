import Foundation

struct StatusesResponse: Decodable {
    let issueStatuses: [IdName]
    enum CodingKeys: String, CodingKey { case issueStatuses = "issue_statuses" }
}

struct PrioritiesResponse: Decodable {
    let issuePriorities: [IdName]
    enum CodingKeys: String, CodingKey { case issuePriorities = "issue_priorities" }
}

struct TrackersResponse: Decodable {
    let trackers: [IdName]
}

struct MembershipsResponse: Decodable {
    let memberships: [Membership]
    let totalCount: Int
    let offset: Int
    let limit: Int

    enum CodingKeys: String, CodingKey {
        case memberships
        case totalCount = "total_count"
        case offset, limit
    }
}

/// A project membership is either a user or a group (groups can be assignees
/// when the instance allows group assignment).
struct Membership: Decodable {
    let id: Int
    let user: IdName?
    let group: IdName?
}

/// Assignable principal of a project, flattened from a membership.
struct ProjectMember {
    let id: Int
    let name: String
    let isGroup: Bool
}

/// GET /projects/:id/versions — includes versions shared from other projects.
/// (`include=versions` on /projects/:id is NOT supported by Redmine and is
/// silently ignored, which is why this needs its own request.)
struct VersionsResponse: Decodable {
    let versions: [VersionInfo]
}

struct VersionInfo: Decodable {
    let id: Int
    let name: String?
    let status: String?   // open | locked | closed
}
