import Foundation
import MCP

enum IssueTools {
    static func handle(_ params: CallTool.Parameters, client: PlanioClient, server: Server? = nil, features: Features) async throws -> CallTool.Result {
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
        case "bulk_get_issues":
            return try await bulkGetIssues(p, params: params, client: client, server: server, features: features)
        case "add_watcher":
            return try await addWatcher(p, client: client)
        case "remove_watcher":
            return try await removeWatcher(p, client: client)
        default:
            return .init(content: [.text("Unknown issue tool: \(params.name)")], isError: true)
        }
    }

    // MARK: - Resolve Helper

    private static func resolveOptional(
        _ p: ToolParams, key: String, field: ResolvableField,
        projectId: Int?, client: PlanioClient
    ) async throws -> Int? {
        guard let raw = p.optionalStringOrInt(key) else { return nil }
        if raw.isEmpty { return nil }
        return try await NameResolver.resolve(raw, field: field, projectId: projectId, client: client)
    }

    // MARK: - List Issues

    private static func listIssues(_ p: ToolParams, client: PlanioClient) async throws -> CallTool.Result {
        var query: [String: String] = [:]

        let projectIdRaw = p.optionalStringOrInt("project_id")
        if let projectIdRaw { query["project_id"] = projectIdRaw }
        let projectIdInt = projectIdRaw.flatMap { Int($0) } // numeric ID for metadata lookups
        query["status_id"] = p.optionalString("status_id") ?? "open"
        if let assignedToId = p.optionalString("assigned_to_id") { query["assigned_to_id"] = assignedToId }
        if let trackerId = try await resolveOptional(p, key: "tracker_id", field: .tracker, projectId: projectIdInt, client: client) {
            query["tracker_id"] = String(trackerId)
        }
        if let sort = p.optionalString("sort") { query["sort"] = sort }
        if let createdOn = p.optionalString("created_on") { query["created_on"] = createdOn }
        if let updatedOn = p.optionalString("updated_on") { query["updated_on"] = updatedOn }
        if let authorId = p.optionalInt("author_id") { query["author_id"] = String(authorId) }
        if let fixedVersionId = try await resolveOptional(p, key: "fixed_version_id", field: .version, projectId: projectIdInt, client: client) {
            query["fixed_version_id"] = String(fixedVersionId)
        }
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
        let filter = parseFilterOptions(p)

        let data = try await client.getIssue(id: issueId)
        let response = try JSONDecoder().decode(IssueResponse.self, from: data)
        return .init(content: [.text(ResponseFormatter.formatIssueDetail(response.issue, features: features, filter: filter))])
    }

    // MARK: - Bulk Get Issues

    private static func bulkGetIssues(_ p: ToolParams, params: CallTool.Parameters, client: PlanioClient, server: Server?, features: Features) async throws -> CallTool.Result {
        let issueIds = try p.requireIntArray("issue_ids")
        let filter = parseFilterOptions(p)

        // Progress helper — throttled to max once per 3 seconds, first notification delayed
        let progressToken = params._meta?.progressToken
        let startMs = UInt64(Date().timeIntervalSince1970 * 1000)
        var lastProgressMs: UInt64 = 0
        let progressIntervalMs: UInt64 = 3000

        let sendProgress: (Double, Double, String) async -> Void = { progress, total, message in
            guard let server, let token = progressToken else { return }
            let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
            guard (nowMs - startMs) >= progressIntervalMs else { return }
            guard lastProgressMs == 0 || (nowMs - lastProgressMs) >= progressIntervalMs else { return }
            lastProgressMs = nowMs

            let notification = ProgressNotification.message(
                .init(progressToken: token, progress: progress, total: total, message: message)
            )
            try? await server.notify(notification)
        }

        // Cache-aware bulk fetch — only uncached IDs hit the API
        let issueData = try await client.getIssues(
            ids: issueIds,
            concurrency: 10,
            onProgress: { completed, total in
                let progress = Double(Int((Double(completed) / Double(total)) * 100.0))
                await sendProgress(progress, 100, "Fetched \(completed) of \(total) issues...")
            }
        )

        // Format in original order, partial failures shown as errors
        let decoder = JSONDecoder()
        var output: [String] = []
        for id in issueIds {
            if let data = issueData[id] {
                do {
                    let response = try decoder.decode(IssueResponse.self, from: data)
                    output.append(ResponseFormatter.formatIssueDetail(response.issue, features: features, filter: filter))
                } catch {
                    output.append("# Issue #\(id): ERROR — \(error.localizedDescription)")
                }
            } else {
                output.append("# Issue #\(id): ERROR — No result")
            }
        }
        return .init(content: [.text(output.joined(separator: "\n\n---\n\n"))])
    }

    // MARK: - Create Issue

    private static func createIssue(_ p: ToolParams, client: PlanioClient, features: Features) async throws -> CallTool.Result {
        guard let projectIdRaw = p.optionalStringOrInt("project_id"), !projectIdRaw.isEmpty else {
            throw ToolError.missingParam("project_id")
        }
        let subject = try p.requireString("subject")

        // Redmine accepts both numeric ID and string identifier in POST body
        var issueData: [String: Any] = [
            "project_id": Int(projectIdRaw) ?? projectIdRaw as Any,
            "subject": subject
        ]

        let projectIdInt = Int(projectIdRaw) // numeric ID for metadata lookups
        if let v = try await resolveOptional(p, key: "tracker_id", field: .tracker, projectId: projectIdInt, client: client) { issueData["tracker_id"] = v }
        if let v = try await resolveOptional(p, key: "status_id", field: .status, projectId: projectIdInt, client: client) { issueData["status_id"] = v }
        if let v = try await resolveOptional(p, key: "priority_id", field: .priority, projectId: projectIdInt, client: client) { issueData["priority_id"] = v }
        if let v = try await resolveOptional(p, key: "assigned_to_id", field: .assignee, projectId: projectIdInt, client: client) { issueData["assigned_to_id"] = v }
        if let parentId = p.optionalInt("parent_issue_id") { issueData["parent_issue_id"] = parentId }
        if let v = try await resolveOptional(p, key: "fixed_version_id", field: .version, projectId: projectIdInt, client: client) { issueData["fixed_version_id"] = v }
        if let desc = p.optionalString("description") { issueData["description"] = desc }
        if let start = p.optionalString("start_date") { issueData["start_date"] = start }
        if let due = p.optionalString("due_date") { issueData["due_date"] = due }
        if let est = p.optionalDouble("estimated_hours") { issueData["estimated_hours"] = est }
        if let isPrivate = p.optionalBool("is_private") { issueData["is_private"] = isPrivate }
        if let v = try await resolveOptional(p, key: "category_id", field: .category, projectId: projectIdInt, client: client) { issueData["category_id"] = v }

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

        // Fetch issue to get project context for resolution
        let issueData_ = try await client.getIssue(id: issueId)
        let issueResponse = try JSONDecoder().decode(IssueResponse.self, from: issueData_)
        let projectId = issueResponse.issue.project?.id

        var issueData: [String: Any] = [:]

        if let subject = p.optionalString("subject") { issueData["subject"] = subject }
        if let v = try await resolveOptional(p, key: "tracker_id", field: .tracker, projectId: projectId, client: client) { issueData["tracker_id"] = v }
        if let v = try await resolveOptional(p, key: "status_id", field: .status, projectId: projectId, client: client) { issueData["status_id"] = v }
        if let v = try await resolveOptional(p, key: "priority_id", field: .priority, projectId: projectId, client: client) { issueData["priority_id"] = v }
        // assigned_to_id: empty string = unassign, otherwise resolve by name
        if let assignedRaw = p.optionalStringOrInt("assigned_to_id") {
            if assignedRaw.isEmpty {
                issueData["assigned_to_id"] = ""
            } else {
                let resolved = try await NameResolver.resolve(assignedRaw, field: .assignee, projectId: projectId, client: client)
                issueData["assigned_to_id"] = resolved
            }
        }
        if let parentId = p.optionalInt("parent_issue_id") { issueData["parent_issue_id"] = parentId }
        if let v = try await resolveOptional(p, key: "fixed_version_id", field: .version, projectId: projectId, client: client) { issueData["fixed_version_id"] = v }
        if let desc = p.optionalString("description") { issueData["description"] = desc }
        if let start = p.optionalString("start_date") { issueData["start_date"] = start }
        if let due = p.optionalString("due_date") { issueData["due_date"] = due }
        if let est = p.optionalDouble("estimated_hours") { issueData["estimated_hours"] = est }
        if let done = p.optionalInt("done_ratio") { issueData["done_ratio"] = done }
        if let notes = p.optionalString("notes") { issueData["notes"] = notes }
        if let isPrivate = p.optionalBool("is_private") { issueData["is_private"] = isPrivate }
        if let v = try await resolveOptional(p, key: "category_id", field: .category, projectId: projectId, client: client) { issueData["category_id"] = v }

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

    // MARK: - Filter Options

    private static func parseFilterOptions(_ p: ToolParams) -> IssueFilterOptions {
        let limit = p.optionalInt("journals_limit") ?? 10
        let since = p.optionalString("journals_since")

        let sections: Set<String>?
        if let sectionsStr = p.optionalString("sections") {
            let parsed = Set(sectionsStr.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            })
            // "metadata" is a virtual section meaning "core only, nothing else"
            sections = parsed.subtracting(["metadata"])
        } else {
            sections = nil  // nil = show everything
        }

        return IssueFilterOptions(sections: sections, journalsLimit: limit, journalsSince: since)
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
