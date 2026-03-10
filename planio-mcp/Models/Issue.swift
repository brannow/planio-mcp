import Foundation

// MARK: - API Response Wrappers

struct IssuesResponse: Decodable {
    let issues: [Issue]
    let totalCount: Int
    let offset: Int
    let limit: Int

    enum CodingKeys: String, CodingKey {
        case issues
        case totalCount = "total_count"
        case offset, limit
    }
}

struct IssueResponse: Decodable {
    let issue: Issue
}

// MARK: - Issue

struct Issue: Decodable {
    let id: Int
    let project: IdName?
    let tracker: IdName?
    let status: IdName?
    let priority: IdName?
    let author: IdName?
    let assignedTo: IdName?
    let category: IdName?
    let fixedVersion: IdName?
    let parent: IssueParent?
    let subject: String?
    let description: String?
    let startDate: String?
    let dueDate: String?
    let doneRatio: Int?
    let isPrivate: Bool?
    let estimatedHours: Double?
    let spentHours: Double?
    let totalSpentHours: Double?
    let customFields: [CustomField]?
    let createdOn: String?
    let updatedOn: String?
    let closedOn: String?

    // Associations (via include param)
    let journals: [Journal]?
    let children: [Issue]?
    let attachments: [Attachment]?
    let relations: [IssueRelation]?
    let watchers: [IdName]?
    let changesets: [Changeset]?

    enum CodingKeys: String, CodingKey {
        case id, project, tracker, status, priority, author
        case assignedTo = "assigned_to"
        case category
        case fixedVersion = "fixed_version"
        case parent, subject, description
        case startDate = "start_date"
        case dueDate = "due_date"
        case doneRatio = "done_ratio"
        case isPrivate = "is_private"
        case estimatedHours = "estimated_hours"
        case spentHours = "spent_hours"
        case totalSpentHours = "total_spent_hours"
        case customFields = "custom_fields"
        case createdOn = "created_on"
        case updatedOn = "updated_on"
        case closedOn = "closed_on"
        case journals, children, attachments, relations, watchers, changesets
    }
}

struct IssueParent: Decodable {
    let id: Int
}

// MARK: - Journal

struct Journal: Decodable {
    let id: Int
    let user: IdName?
    let notes: String?
    let createdOn: String?
    let privateNotes: Bool?
    let details: [JournalDetail]?

    enum CodingKeys: String, CodingKey {
        case id, user, notes
        case createdOn = "created_on"
        case privateNotes = "private_notes"
        case details
    }
}

struct JournalDetail: Decodable {
    let property: String?
    let name: String?
    let oldValue: AnyCodableValue?
    let newValue: AnyCodableValue?

    enum CodingKeys: String, CodingKey {
        case property, name
        case oldValue = "old_value"
        case newValue = "new_value"
    }
}

// MARK: - Relations & Attachments

struct IssueRelation: Decodable {
    let id: Int
    let issueId: Int
    let issueToId: Int
    let relationType: String?
    let delay: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case issueId = "issue_id"
        case issueToId = "issue_to_id"
        case relationType = "relation_type"
        case delay
    }
}

struct Attachment: Decodable {
    let id: Int
    let filename: String?
    let filesize: Int?
    let contentType: String?
    let description: String?
    let contentUrl: String?
    let author: IdName?
    let createdOn: String?

    enum CodingKeys: String, CodingKey {
        case id, filename, filesize
        case contentType = "content_type"
        case description
        case contentUrl = "content_url"
        case author
        case createdOn = "created_on"
    }
}

struct Changeset: Decodable {
    let revision: String?
    let user: IdName?
    let comments: String?
    let committedOn: String?

    enum CodingKeys: String, CodingKey {
        case revision, user, comments
        case committedOn = "committed_on"
    }
}

// MARK: - Checklist Parsing

struct ChecklistItem {
    let id: Int?
    let subject: String
    let isDone: Bool
    let position: Int
}

extension Issue {
    func parseChecklists() -> [ChecklistItem] {
        guard let journals else { return [] }

        var latestChecklist: [ChecklistItem] = []

        for journal in journals {
            guard let details = journal.details else { continue }
            for detail in details {
                guard detail.name == "checklist" else { continue }
                guard let newValueStr = detail.newValue?.asString else { continue }

                // Parse the JSON checklist data
                guard let data = newValueStr.data(using: .utf8),
                      let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    continue
                }

                latestChecklist = items.compactMap { item in
                    guard let subject = item["subject"] as? String else { return nil }
                    let id = item["id"] as? Int
                    let isDone = item["is_done"] as? Bool ?? false
                    let position = item["position"] as? Int ?? 0
                    return ChecklistItem(id: id, subject: subject, isDone: isDone, position: position)
                }.sorted { $0.position < $1.position }
            }
        }

        return latestChecklist
    }
}

// MARK: - Shared Types

struct IdName: Decodable {
    let id: Int
    let name: String?
}

struct CustomField: Decodable {
    let id: Int
    let name: String?
    let value: AnyCodableValue?
    let multiple: Bool?
}

/// Handles JSON values that can be String, Int, Bool, Array, or null
enum AnyCodableValue: Decodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AnyCodableValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let a = try? container.decode([AnyCodableValue].self) {
            self = .array(a)
        } else {
            self = .null
        }
    }

    var asString: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return String(b)
        default: return nil
        }
    }
}
