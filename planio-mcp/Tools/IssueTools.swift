import Foundation
import MCP

enum IssueTools {
    static func handle(_ params: CallTool.Parameters, client: PlanioClient, features: Features) async throws -> CallTool.Result {
        let p = ToolParams(args: params.arguments)

        switch params.name {
        case "list_issues":
            return try await listIssues(p, client: client)
        case "get_issue":
            return try await getIssue(p, client: client, features: features)
        case "create_issue":
            return try await createIssue(p, client: client, features: features)
        case "update_issue":
            return try await updateIssue(p, client: client, features: features)
        case "delete_issue":
            return try await deleteIssue(p, client: client)
        case "add_watcher":
            return try await addWatcher(p, client: client)
        case "remove_watcher":
            return try await removeWatcher(p, client: client)
        default:
            return .init(content: [.text("Unknown issue tool: \(params.name)")], isError: true)
        }
    }

    // MARK: - List Issues

    private static func listIssues(_ p: ToolParams, client: PlanioClient) async throws -> CallTool.Result {
        var query: [String: String] = [:]

        if let projectId = p.optionalInt("project_id") { query["project_id"] = String(projectId) }
        if let statusId = p.optionalString("status_id") { query["status_id"] = statusId }
        if let assignedToId = p.optionalString("assigned_to_id") { query["assigned_to_id"] = assignedToId }
        if let trackerId = p.optionalInt("tracker_id") { query["tracker_id"] = String(trackerId) }
        if let sort = p.optionalString("sort") { query["sort"] = sort }
        if let createdOn = p.optionalString("created_on") { query["created_on"] = createdOn }
        if let updatedOn = p.optionalString("updated_on") { query["updated_on"] = updatedOn }
        if let authorId = p.optionalInt("author_id") { query["author_id"] = String(authorId) }
        if let fixedVersionId = p.optionalInt("fixed_version_id") { query["fixed_version_id"] = String(fixedVersionId) }
        if let limit = p.optionalInt("limit") { query["limit"] = String(limit) }
        if let offset = p.optionalInt("offset") { query["offset"] = String(offset) }

        // Support custom field filters (cf_X)
        if let args = p.args {
            for (key, value) in args where key.hasPrefix("cf_") {
                if let v = value.stringValue { query[key] = v }
            }
        }

        let response: IssuesResponse = try await client.get(
            path: "/issues",
            queryParams: query.isEmpty ? nil : query
        )
        return .init(content: [.text(ResponseFormatter.formatIssueList(response))])
    }

    // MARK: - Get Issue

    private static func getIssue(_ p: ToolParams, client: PlanioClient, features: Features) async throws -> CallTool.Result {
        let issueId = try p.requireInt("issue_id")
        let include = p.optionalString("include")

        let data = try await client.getIssue(id: issueId, include: include)
        let response = try JSONDecoder().decode(IssueResponse.self, from: data)
        return .init(content: [.text(ResponseFormatter.formatIssueDetail(response.issue, features: features))])
    }

    // MARK: - Create Issue

    private static func createIssue(_ p: ToolParams, client: PlanioClient, features: Features) async throws -> CallTool.Result {
        let projectId = try p.requireInt("project_id")
        let subject = try p.requireString("subject")

        var issueData: [String: Any] = [
            "project_id": projectId,
            "subject": subject
        ]

        if let trackerId = p.optionalInt("tracker_id") { issueData["tracker_id"] = trackerId }
        if let statusId = p.optionalInt("status_id") { issueData["status_id"] = statusId }
        if let priorityId = p.optionalInt("priority_id") { issueData["priority_id"] = priorityId }
        if let assignedToId = p.optionalInt("assigned_to_id") { issueData["assigned_to_id"] = assignedToId }
        if let parentId = p.optionalInt("parent_issue_id") { issueData["parent_issue_id"] = parentId }
        if let versionId = p.optionalInt("fixed_version_id") { issueData["fixed_version_id"] = versionId }
        if let desc = p.optionalString("description") { issueData["description"] = desc }
        if let start = p.optionalString("start_date") { issueData["start_date"] = start }
        if let due = p.optionalString("due_date") { issueData["due_date"] = due }
        if let est = p.optionalDouble("estimated_hours") { issueData["estimated_hours"] = est }
        if let isPrivate = p.optionalBool("is_private") { issueData["is_private"] = isPrivate }
        if let categoryId = p.optionalInt("category_id") { issueData["category_id"] = categoryId }

        // Custom fields
        if let customFields = p.optionalArray("custom_fields") {
            issueData["custom_fields"] = customFields.compactMap { cf -> [String: Any]? in
                guard let obj = cf.objectValue,
                      let id = obj["id"]?.intValue else { return nil }
                let value = obj["value"]?.stringValue ?? ""
                return ["id": id, "value": value]
            }
        }

        // Watcher user IDs
        if let watcherIds = p.optionalArray("watcher_user_ids") {
            issueData["watcher_user_ids"] = watcherIds.compactMap { $0.intValue }
        }

        // Checklists (requires plugin, e.g. Planio or RedmineUP Checklists)
        if features.checklists, let checklists = p.optionalObject("checklists_attributes") {
            issueData["checklists_attributes"] = convertChecklistAttributes(checklists)
        }

        let response: IssueResponse = try await client.post(
            path: "/issues",
            body: ["issue": issueData]
        )
        return .init(content: [.text("Issue created successfully.\n\n\(ResponseFormatter.formatIssueDetail(response.issue))")])
    }

    // MARK: - Update Issue

    private static func updateIssue(_ p: ToolParams, client: PlanioClient, features: Features) async throws -> CallTool.Result {
        let issueId = try p.requireInt("issue_id")

        var issueData: [String: Any] = [:]

        if let subject = p.optionalString("subject") { issueData["subject"] = subject }
        if let trackerId = p.optionalInt("tracker_id") { issueData["tracker_id"] = trackerId }
        if let statusId = p.optionalInt("status_id") { issueData["status_id"] = statusId }
        if let priorityId = p.optionalInt("priority_id") { issueData["priority_id"] = priorityId }
        if let assignedToId = p.optionalString("assigned_to_id") {
            // Support empty string to unassign
            if assignedToId.isEmpty {
                issueData["assigned_to_id"] = ""
            } else if let intId = Int(assignedToId) {
                issueData["assigned_to_id"] = intId
            }
        }
        if let parentId = p.optionalInt("parent_issue_id") { issueData["parent_issue_id"] = parentId }
        if let versionId = p.optionalInt("fixed_version_id") { issueData["fixed_version_id"] = versionId }
        if let desc = p.optionalString("description") { issueData["description"] = desc }
        if let start = p.optionalString("start_date") { issueData["start_date"] = start }
        if let due = p.optionalString("due_date") { issueData["due_date"] = due }
        if let est = p.optionalDouble("estimated_hours") { issueData["estimated_hours"] = est }
        if let done = p.optionalInt("done_ratio") { issueData["done_ratio"] = done }
        if let notes = p.optionalString("notes") { issueData["notes"] = notes }
        if let isPrivate = p.optionalBool("is_private") { issueData["is_private"] = isPrivate }
        if let categoryId = p.optionalInt("category_id") { issueData["category_id"] = categoryId }

        // Custom fields
        if let customFields = p.optionalArray("custom_fields") {
            issueData["custom_fields"] = customFields.compactMap { cf -> [String: Any]? in
                guard let obj = cf.objectValue,
                      let id = obj["id"]?.intValue else { return nil }
                let value = obj["value"]?.stringValue ?? ""
                return ["id": id, "value": value]
            }
        }

        // Checklists (requires plugin, e.g. Planio or RedmineUP Checklists)
        if features.checklists, let checklists = p.optionalObject("checklists_attributes") {
            issueData["checklists_attributes"] = convertChecklistAttributes(checklists)
        }

        guard !issueData.isEmpty else {
            return .init(content: [.text("No fields to update. Provide at least one field to change.")], isError: true)
        }

        _ = try await client.put(path: "/issues/\(issueId)", body: ["issue": issueData])
        await client.invalidateIssueCache(id: issueId)
        return .init(content: [.text("Issue #\(issueId) updated successfully.")])
    }

    // MARK: - Delete Issue

    private static func deleteIssue(_ p: ToolParams, client: PlanioClient) async throws -> CallTool.Result {
        let issueId = try p.requireInt("issue_id")
        _ = try await client.delete(path: "/issues/\(issueId)")
        await client.invalidateIssueCache(id: issueId)
        return .init(content: [.text("Issue #\(issueId) deleted successfully.")])
    }

    // MARK: - Watchers

    private static func addWatcher(_ p: ToolParams, client: PlanioClient) async throws -> CallTool.Result {
        let issueId = try p.requireInt("issue_id")
        let userId = try p.requireInt("user_id")
        _ = try await client.put(path: "/issues/\(issueId)/watchers", body: ["user_id": userId])
        return .init(content: [.text("User \(userId) added as watcher to issue #\(issueId).")])
    }

    private static func removeWatcher(_ p: ToolParams, client: PlanioClient) async throws -> CallTool.Result {
        let issueId = try p.requireInt("issue_id")
        let userId = try p.requireInt("user_id")
        _ = try await client.delete(path: "/issues/\(issueId)/watchers/\(userId)")
        return .init(content: [.text("User \(userId) removed as watcher from issue #\(issueId).")])
    }

    // MARK: - Helpers

    private static func convertChecklistAttributes(_ attrs: [String: Value]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for (key, value) in attrs {
            guard let obj = value.objectValue else { continue }
            var item: [String: Any] = [:]
            if let id = Int(key) { item["id"] = id }
            // Also accept id inside the value (redundant but prevents agent mistakes)
            if item["id"] == nil, let innerId = obj["id"]?.intValue { item["id"] = innerId }
            if let subject = obj["subject"]?.stringValue { item["subject"] = subject }
            if let isDone = obj["is_done"]?.boolValue { item["is_done"] = isDone }
            if let isSection = obj["is_section"]?.boolValue { item["is_section"] = isSection }
            if let position = obj["position"]?.intValue { item["position"] = position }
            if let destroy = obj["_destroy"]?.boolValue { item["_destroy"] = destroy }
            result.append(item)
        }
        return result
    }
}
