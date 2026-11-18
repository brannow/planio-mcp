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
        case "get_issue_tree":
            return try await getIssueTree(p, client: client)
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
        project: String?, client: PlanioClient
    ) async throws -> Int? {
        guard let raw = p.optionalStringOrInt(key) else { return nil }
        if raw.isEmpty { return nil }
        return try await NameResolver.resolve(raw, field: field, project: project, client: client)
    }

    /// Error result for write tools. States explicitly that nothing was saved:
    /// Redmine applies an issue create/update atomically, so on any failure the
    /// comment is not posted either — the agent must retry, not assume it landed.
    private static func notWritten(_ what: String, _ error: Error) -> CallTool.Result {
        .init(content: [.text("Nothing was written (\(what)); no field changed and no comment was posted. Cause: \(error.localizedDescription)")], isError: true)
    }

    /// Only a 4xx answer proves Redmine rejected the request. Timeouts, dropped
    /// connections and 5xx (e.g. a proxy 502 after Redmine already committed)
    /// leave the outcome unknown — claiming "nothing was written" there would
    /// make the agent retry and post a duplicate comment / create a duplicate.
    private static func isDefiniteRejection(_ error: Error) -> Bool {
        if case ToolError.apiError(let code, _) = error { return (400..<500).contains(code) }
        return false
    }

    // MARK: - List Issues

    /// search_in -> Redmine issue filter. Only these four were verified against
    /// Planio: an UNKNOWN filter name is silently ignored and returns all issues.
    private static let searchFilters = [
        "any": "any_searchable", "subject": "subject",
        "description": "description", "notes": "notes"
    ]

    private static func listIssues(_ p: ToolParams, client: PlanioClient) async throws -> CallTool.Result {
        var query: [String: String] = [:]
        var applied: [String] = []

        let project = p.optionalStringOrInt("project_id").flatMap { $0.isEmpty ? nil : $0 }
        if let project { query["project_id"] = project; applied.append("project \(project)") }

        let status = try await resolveStatusFilter(p.optionalStringOrInt("status_id") ?? "open", client: client)
        query["status_id"] = status.query
        applied.append("status \(status.label)")

        if let assignee = p.optionalStringOrInt("assigned_to_id"), !assignee.isEmpty {
            // 'me', '*' (anyone), '!*' (nobody) and IDs are native Redmine values
            if ["me", "*", "!*"].contains(assignee.lowercased()) || Int(assignee) != nil {
                query["assigned_to_id"] = assignee.lowercased()
            } else {
                let id = try await NameResolver.resolveUser(assignee, project: project, client: client)
                query["assigned_to_id"] = String(id)
                applied.append("assignee \(assignee) → \(await NameResolver.userLabel(id, project: project, client: client))")
            }
            if Int(assignee) != nil || ["me", "*", "!*"].contains(assignee.lowercased()) {
                applied.append("assignee \(assignee)")
            }
        }

        if let text = p.optionalString("query")?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            let scope = (p.optionalString("search_in") ?? "any").lowercased()
            guard let filter = searchFilters[scope] else {
                throw ToolError.invalid("search_in must be one of: any, subject, description, notes")
            }
            query[filter] = "~" + text
            applied.append("text '\(text)' in \(scope == "any" ? "subject/description/comments" : scope)")
        }

        if let parentId = p.optionalStringOrInt("parent_id") { query["parent_id"] = parentId; applied.append("parent \(parentId)") }
        if let trackerId = try await resolveOptional(p, key: "tracker_id", field: .tracker, project: project, client: client) {
            query["tracker_id"] = String(trackerId)
            applied.append("tracker \(p.optionalStringOrInt("tracker_id") ?? "") (#\(trackerId))")
        }
        if let sort = p.optionalString("sort") { query["sort"] = sort }
        if let createdOn = p.optionalString("created_on") { query["created_on"] = createdOn; applied.append("created \(createdOn)") }
        if let updatedOn = p.optionalString("updated_on") { query["updated_on"] = updatedOn; applied.append("updated \(updatedOn)") }
        if let authorId = p.optionalInt("author_id") { query["author_id"] = String(authorId) }
        if let fixedVersionId = try await resolveOptional(p, key: "fixed_version_id", field: .version, project: project, client: client) {
            query["fixed_version_id"] = String(fixedVersionId)
            applied.append("version \(p.optionalStringOrInt("fixed_version_id") ?? "") (#\(fixedVersionId))")
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
        return .init(content: [.text(ResponseFormatter.formatIssueList(response, filters: applied.joined(separator: ", ")))])
    }

    /// status_id accepts 'open' | 'closed' | '*' or one/several status names or
    /// IDs separated by ',' or '|' (e.g. 'Feedback, Abnahme Kund:in').
    static func resolveStatusFilter(_ raw: String, client: PlanioClient) async throws -> (query: String, label: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        switch trimmed.lowercased() {
        case "open", "closed", "*": return (trimmed.lowercased(), trimmed.lowercased())
        case "all": return ("*", "*")
        default: break
        }
        // A single name may itself contain a comma — try the whole string first
        if let id = try? await NameResolver.resolve(trimmed, field: .status, project: nil, client: client) {
            return (String(id), trimmed)
        }
        let parts = trimmed.split(whereSeparator: { $0 == "," || $0 == "|" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var ids: [String] = []
        for part in parts {
            if ["open", "closed", "*", "all"].contains(part.lowercased()) {
                throw ToolError.invalid("status_id: 'open', 'closed' and '*' cannot be combined with specific statuses")
            }
            ids.append(String(try await NameResolver.resolve(part, field: .status, project: nil, client: client)))
        }
        return (ids.joined(separator: "|"), parts.joined(separator: " | "))
    }

    // MARK: - Get Issue

    private static func getIssue(_ p: ToolParams, client: PlanioClient, features: Features) async throws -> CallTool.Result {
        let issueId = try p.requireInt("issue_id")
        let filter = parseFilterOptions(p)

        let data = try await client.getIssue(id: issueId)
        let issue = try JSONDecoder().decode(IssueResponse.self, from: data).issue
        let lookup = filter.shouldInclude("journals") ? await NameLookup.build(for: [issue], client: client) : .empty
        return .init(content: [.text(ResponseFormatter.formatIssueDetail(issue, features: features, filter: filter, lookup: lookup))])
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

        // Decode all first so the name lookup is built once for the whole batch
        let decoder = JSONDecoder()
        var decoded: [Int: Result<Issue, Error>] = [:]
        for id in issueIds {
            guard let data = issueData[id] else { continue }
            decoded[id] = Result { try decoder.decode(IssueResponse.self, from: data).issue }
        }
        let okIssues = decoded.values.compactMap { try? $0.get() }
        let lookup = filter.shouldInclude("journals") ? await NameLookup.build(for: okIssues, client: client) : .empty

        // Format in original order, partial failures shown as errors
        var output: [String] = []
        for id in issueIds {
            switch decoded[id] {
            case .success(let issue)?:
                output.append(ResponseFormatter.formatIssueDetail(issue, features: features, filter: filter, lookup: lookup))
            case .failure(let error)?:
                output.append("# Issue #\(id): ERROR — \(error.localizedDescription)")
            case nil:
                output.append("# Issue #\(id): ERROR — No result")
            }
        }
        return .init(content: [.text(output.joined(separator: "\n\n---\n\n"))])
    }

    // MARK: - Issue Tree

    private static func getIssueTree(_ p: ToolParams, client: PlanioClient) async throws -> CallTool.Result {
        let issueId = try p.requireInt("issue_id")

        // Root detail: carries the nested descendant tree (include=children)
        // and the server-side rollups (total_estimated_hours, total_spent_hours).
        let data = try await client.getIssue(id: issueId)
        let root = try JSONDecoder().decode(IssueResponse.self, from: data).issue

        // Collect all descendant IDs from the nested children structure
        var descendantIds: [Int] = []
        func collect(_ issue: Issue) {
            for child in issue.children ?? [] {
                descendantIds.append(child.id)
                collect(child)
            }
        }
        collect(root)

        guard !descendantIds.isEmpty else {
            return .init(content: [.text(ResponseFormatter.formatIssueTree(root: root, descendants: []))])
        }

        // One list request per 100 descendants — brings status, assignee,
        // estimates, done ratio for every node in the subtree.
        let descendants = try await client.fetchIssuesByIds(descendantIds)
        return .init(content: [.text(ResponseFormatter.formatIssueTree(root: root, descendants: descendants))])
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

        do {
            // Names resolve against this project (ID or identifier both work)
            let project: String? = projectIdRaw
            if let v = try await resolveOptional(p, key: "tracker_id", field: .tracker, project: project, client: client) { issueData["tracker_id"] = v }
            if let v = try await resolveOptional(p, key: "status_id", field: .status, project: project, client: client) { issueData["status_id"] = v }
            if let v = try await resolveOptional(p, key: "priority_id", field: .priority, project: project, client: client) { issueData["priority_id"] = v }
            if let v = try await resolveOptional(p, key: "assigned_to_id", field: .assignee, project: project, client: client) { issueData["assigned_to_id"] = v }
            if let v = try await resolveOptional(p, key: "fixed_version_id", field: .version, project: project, client: client) { issueData["fixed_version_id"] = v }
            if let v = try await resolveOptional(p, key: "category_id", field: .category, project: project, client: client) { issueData["category_id"] = v }
        } catch {
            return notWritten("issue was not created", error)
        }
        if let parentId = p.optionalInt("parent_issue_id") { issueData["parent_issue_id"] = parentId }
        if let desc = p.optionalString("description") { issueData["description"] = desc }
        if let start = p.optionalString("start_date") { issueData["start_date"] = start }
        if let due = p.optionalString("due_date") { issueData["due_date"] = due }
        if let est = p.optionalDouble("estimated_hours") { issueData["estimated_hours"] = est }
        if let isPrivate = p.optionalBool("is_private") { issueData["is_private"] = isPrivate }

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

        let response: IssueResponse
        do {
            response = try await client.post(path: "/issues", body: ["issue": issueData])
        } catch where isDefiniteRejection(error) {
            return notWritten("issue was not created", error)
        } catch {
            return .init(content: [.text("Outcome UNKNOWN — the issue MAY have been created (\(error.localizedDescription)). Check list_issues with sort=created_on:desc before retrying, otherwise you may create a duplicate.")], isError: true)
        }
        return .init(content: [.text("Issue created successfully.\n\n\(ResponseFormatter.formatIssueDetail(response.issue))")])
    }

    // MARK: - Update Issue

    private static func updateIssue(_ p: ToolParams, client: PlanioClient, features: Features) async throws -> CallTool.Result {
        let issueId = try p.requireInt("issue_id")

        // Fresh fetch (not cached): gives the project context for name resolution
        // AND the journal baseline — only journals newer than this one can be the
        // comment we are about to post (an older identical "Erledigt" must not count).
        await client.invalidateIssueCache(id: issueId)
        let issueData_ = try await client.getIssue(id: issueId)
        let issueResponse = try JSONDecoder().decode(IssueResponse.self, from: issueData_)
        let project = issueResponse.issue.project.map { String($0.id) }
        let journalBaseline = issueResponse.issue.journals?.map(\.id).max() ?? 0

        var issueData: [String: Any] = [:]

        // Every name is resolved BEFORE anything is sent; a failure aborts the
        // whole call so a comment never goes out with half of its field changes.
        do {
            if let v = try await resolveOptional(p, key: "tracker_id", field: .tracker, project: project, client: client) { issueData["tracker_id"] = v }
            if let v = try await resolveOptional(p, key: "status_id", field: .status, project: project, client: client) { issueData["status_id"] = v }
            if let v = try await resolveOptional(p, key: "priority_id", field: .priority, project: project, client: client) { issueData["priority_id"] = v }
            // assigned_to_id: empty string = unassign, otherwise resolve via project members
            if let assignedRaw = p.optionalStringOrInt("assigned_to_id") {
                issueData["assigned_to_id"] = assignedRaw.isEmpty
                    ? ""
                    : try await NameResolver.resolveUser(assignedRaw, project: project, client: client)
            }
            if let v = try await resolveOptional(p, key: "fixed_version_id", field: .version, project: project, client: client) { issueData["fixed_version_id"] = v }
            if let v = try await resolveOptional(p, key: "category_id", field: .category, project: project, client: client) { issueData["category_id"] = v }
        } catch {
            return notWritten("#\(issueId) unchanged", error)
        }

        if let subject = p.optionalString("subject") { issueData["subject"] = subject }
        if let parentId = p.optionalInt("parent_issue_id") { issueData["parent_issue_id"] = parentId }
        if let desc = p.optionalString("description") { issueData["description"] = desc }
        if let start = p.optionalString("start_date") { issueData["start_date"] = start }
        if let due = p.optionalString("due_date") { issueData["due_date"] = due }
        if let est = p.optionalDouble("estimated_hours") { issueData["estimated_hours"] = est }
        if let done = p.optionalInt("done_ratio") { issueData["done_ratio"] = done }
        if let notes = p.optionalString("notes") { issueData["notes"] = notes }
        if let privateNotes = p.optionalBool("private_notes") {
            guard let notes = issueData["notes"] as? String, !notes.isEmpty else {
                return .init(content: [.text("private_notes requires notes. Nothing was written. Existing comments cannot be edited, deleted, restored or switched private/public via the API (Planio returns 403 for journal edits) — add a new note instead.")], isError: true)
            }
            issueData["private_notes"] = privateNotes
        }
        if let isPrivate = p.optionalBool("is_private") { issueData["is_private"] = isPrivate }

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

        var putError: Error?
        do {
            _ = try await client.put(path: "/issues/\(issueId)", body: ["issue": issueData])
        } catch where isDefiniteRejection(error) {
            await client.invalidateIssueCache(id: issueId)
            return notWritten("#\(issueId) unchanged", error)
        } catch {
            // Unknown outcome: fall through and let the re-read tell what landed
            putError = error
        }
        await client.invalidateIssueCache(id: issueId)

        // Re-read and compare: Redmine silently drops attributes the role or
        // workflow may not change (e.g. a forbidden status transition) and still
        // answers 204, so "updated" alone would be a lie in exactly that case.
        do {
            let after = try JSONDecoder().decode(IssueResponse.self, from: try await client.getIssue(id: issueId)).issue
            var text = UpdateVerifier.report(issueId: issueId, requested: issueData, rawInput: p, after: after, journalBaseline: journalBaseline)
            if let putError {
                text = "The update request failed with an unclear outcome (\(putError.localizedDescription)). The issue was re-read — trust ONLY the lines below, retry only what is marked ⚠.\n\n" + text
            }
            return .init(content: [.text(text)], isError: putError != nil)
        } catch {
            if let putError {
                return .init(content: [.text("Outcome UNKNOWN for #\(issueId): the update failed unclearly (\(putError.localizedDescription)) and re-reading failed too (\(error.localizedDescription)). Check with get_issue before retrying, otherwise the comment may be posted twice.")], isError: true)
            }
            return .init(content: [.text("Issue #\(issueId) updated (Redmine accepted the request). Could not re-read it to verify: \(error.localizedDescription)")])
        }
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
        let since = p.optionalString("journals_since").map(DateText.normalizeSince)

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

        var options = IssueFilterOptions(sections: sections, journalsLimit: limit, journalsSince: since)
        options.notesOnly = p.optionalBool("notes_only") ?? false
        return options
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
