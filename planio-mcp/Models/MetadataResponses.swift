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
