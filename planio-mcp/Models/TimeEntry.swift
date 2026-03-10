import Foundation

struct TimeEntriesResponse: Decodable {
    let timeEntries: [TimeEntry]
    let totalCount: Int
    let offset: Int
    let limit: Int

    enum CodingKeys: String, CodingKey {
        case timeEntries = "time_entries"
        case totalCount = "total_count"
        case offset, limit
    }
}

struct TimeEntryResponse: Decodable {
    let timeEntry: TimeEntry

    enum CodingKeys: String, CodingKey {
        case timeEntry = "time_entry"
    }
}

struct TimeEntry: Decodable {
    let id: Int
    let project: IdName?
    let issue: TimeEntryIssue?
    let user: IdName?
    let activity: IdName?
    let hours: Double?
    let comments: String?
    let spentOn: String?
    let customFields: [CustomField]?
    let createdOn: String?
    let updatedOn: String?

    enum CodingKeys: String, CodingKey {
        case id, project, issue, user, activity, hours, comments
        case spentOn = "spent_on"
        case customFields = "custom_fields"
        case createdOn = "created_on"
        case updatedOn = "updated_on"
    }
}

struct TimeEntryIssue: Decodable {
    let id: Int
}
