import Foundation

struct ProjectsResponse: Decodable {
    let projects: [Project]
    let totalCount: Int
    let offset: Int
    let limit: Int

    enum CodingKeys: String, CodingKey {
        case projects
        case totalCount = "total_count"
        case offset, limit
    }
}

struct ProjectResponse: Decodable {
    let project: Project
}

struct Project: Decodable {
    let id: Int
    let name: String?
    let identifier: String?
    let description: String?
    let status: Int?
    let isPublic: Bool?
    let customFields: [CustomField]?
    let createdOn: String?
    let updatedOn: String?

    // Associations (via include param)
    let trackers: [IdName]?
    let issueCategories: [IdName]?
    let enabledModules: [EnabledModule]?
    let timeEntryActivities: [IdName]?
    let versions: [IdName]?

    enum CodingKeys: String, CodingKey {
        case id, name, identifier, description, status
        case isPublic = "is_public"
        case customFields = "custom_fields"
        case createdOn = "created_on"
        case updatedOn = "updated_on"
        case trackers
        case issueCategories = "issue_categories"
        case enabledModules = "enabled_modules"
        case timeEntryActivities = "time_entry_activities"
        case versions
    }
}

struct EnabledModule: Decodable {
    let id: Int?
    let name: String?
}
