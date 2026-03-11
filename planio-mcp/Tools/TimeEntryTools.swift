import Foundation
import MCP

enum TimeEntryTools {
    static func handle(_ params: CallTool.Parameters, client: PlanioClient) async throws -> CallTool.Result {
        let p = ToolParams(args: params.arguments)

        switch params.name {
        case "list_time_entries":
            return try await listTimeEntries(p, client: client)
        case "get_time_entry":
            return try await getTimeEntry(p, client: client)
        case "create_time_entry":
            return try await createTimeEntry(p, client: client)
        case "update_time_entry":
            return try await updateTimeEntry(p, client: client)
        case "delete_time_entry":
            return try await deleteTimeEntry(p, client: client)
        default:
            return .init(content: [.text("Unknown time entry tool: \(params.name)")], isError: true)
        }
    }

    private static func listTimeEntries(_ p: ToolParams, client: PlanioClient) async throws -> CallTool.Result {
        var query: [String: String] = [:]
        if let projectId = p.optionalStringOrInt("project_id") { query["project_id"] = projectId }
        if let issueId = p.optionalInt("issue_id") { query["issue_id"] = String(issueId) }
        if let userId = p.optionalInt("user_id") { query["user_id"] = String(userId) }
        if let from = p.optionalString("from") { query["from"] = from }
        if let to = p.optionalString("to") { query["to"] = to }
        if let limit = p.optionalInt("limit") { query["limit"] = String(limit) }
        if let offset = p.optionalInt("offset") { query["offset"] = String(offset) }

        let response: TimeEntriesResponse = try await client.get(
            path: "/time_entries",
            queryParams: query.isEmpty ? nil : query
        )
        return .init(content: [.text(ResponseFormatter.formatTimeEntryList(response))])
    }

    private static func getTimeEntry(_ p: ToolParams, client: PlanioClient) async throws -> CallTool.Result {
        let id = try p.requireInt("id")
        let response: TimeEntryResponse = try await client.get(path: "/time_entries/\(id)")
        return .init(content: [.text(ResponseFormatter.formatTimeEntryDetail(response.timeEntry))])
    }

    private static func createTimeEntry(_ p: ToolParams, client: PlanioClient) async throws -> CallTool.Result {
        let hours = try p.requireDouble("hours")

        // Determine project context for activity resolution
        let issueId = p.optionalInt("issue_id")
        let projectIdRaw = p.optionalStringOrInt("project_id")

        guard issueId != nil || projectIdRaw != nil else {
            return .init(content: [.text("Either issue_id or project_id is required.")], isError: true)
        }

        // Resolve numeric project ID for metadata lookups (activity resolution)
        let resolvedProjectId: Int?
        if let projectIdRaw, let pid = Int(projectIdRaw) {
            resolvedProjectId = pid
        } else if let issueId {
            let issueData = try await client.getIssue(id: issueId)
            let issueResponse = try JSONDecoder().decode(IssueResponse.self, from: issueData)
            resolvedProjectId = issueResponse.issue.project?.id
        } else {
            resolvedProjectId = nil
        }

        // Resolve activity by name or ID
        guard let activityRaw = p.optionalStringOrInt("activity_id") else {
            return .init(content: [.text("Missing required parameter: activity_id")], isError: true)
        }
        let activityId = try await NameResolver.resolve(activityRaw, field: .activity, projectId: resolvedProjectId, client: client)

        var entryData: [String: Any] = [
            "hours": hours,
            "activity_id": activityId
        ]

        if let issueId { entryData["issue_id"] = issueId }
        if let projectIdRaw { entryData["project_id"] = Int(projectIdRaw) ?? projectIdRaw as Any }
        if let spentOn = p.optionalString("spent_on") { entryData["spent_on"] = spentOn }
        if let comments = p.optionalString("comments") { entryData["comments"] = comments }

        // Custom fields
        if let customFields = p.optionalArray("custom_fields") {
            entryData["custom_fields"] = customFields.compactMap { cf -> [String: Any]? in
                guard let obj = cf.objectValue,
                      let id = obj["id"]?.intValue else { return nil }
                let value = obj["value"]?.stringValue ?? ""
                return ["id": id, "value": value]
            }
        }

        let response: TimeEntryResponse = try await client.post(
            path: "/time_entries",
            body: ["time_entry": entryData]
        )

        var output = "Time entry created successfully.\n\n\(ResponseFormatter.formatTimeEntryDetail(response.timeEntry))"

        // Phase 3: Time budget context after booking against an issue
        if let issueId {
            await client.invalidateIssueCache(id: issueId)
            if let issueData = try? await client.getIssue(id: issueId),
               let issueResponse = try? JSONDecoder().decode(IssueResponse.self, from: issueData) {
                let issue = issueResponse.issue
                if let spent = issue.spentHours, spent > 0 {
                    if let est = issue.estimatedHours, est > 0 {
                        output += "\n\nIssue #\(issueId) time: \(String(format: "%.1f", spent))h of \(String(format: "%.1f", est))h"
                    } else {
                        output += "\n\nIssue #\(issueId) time: \(String(format: "%.1f", spent))h spent"
                    }
                }
            }
        }

        return .init(content: [.text(output)])
    }

    private static func updateTimeEntry(_ p: ToolParams, client: PlanioClient) async throws -> CallTool.Result {
        let id = try p.requireInt("id")

        var entryData: [String: Any] = [:]
        if let hours = p.optionalDouble("hours") { entryData["hours"] = hours }
        // Resolve activity by name — use project_id if available for context
        if let activityRaw = p.optionalStringOrInt("activity_id") {
            let projectIdInt = p.optionalStringOrInt("project_id").flatMap { Int($0) }
            let activityId = try await NameResolver.resolve(activityRaw, field: .activity, projectId: projectIdInt, client: client)
            entryData["activity_id"] = activityId
        }
        if let issueId = p.optionalInt("issue_id") { entryData["issue_id"] = issueId }
        if let projectIdRaw = p.optionalStringOrInt("project_id") { entryData["project_id"] = Int(projectIdRaw) ?? projectIdRaw as Any }
        if let spentOn = p.optionalString("spent_on") { entryData["spent_on"] = spentOn }
        if let comments = p.optionalString("comments") { entryData["comments"] = comments }

        guard !entryData.isEmpty else {
            return .init(content: [.text("No fields to update.")], isError: true)
        }

        _ = try await client.put(path: "/time_entries/\(id)", body: ["time_entry": entryData])
        return .init(content: [.text("Time entry #\(id) updated successfully.")])
    }

    private static func deleteTimeEntry(_ p: ToolParams, client: PlanioClient) async throws -> CallTool.Result {
        let id = try p.requireInt("id")
        _ = try await client.delete(path: "/time_entries/\(id)")
        return .init(content: [.text("Time entry #\(id) deleted successfully.")])
    }
}

extension ToolParams {
    func requireDouble(_ key: String) throws -> Double {
        guard let val = args?[key]?.doubleValue else {
            throw ToolError.missingParam(key)
        }
        return val
    }
}
