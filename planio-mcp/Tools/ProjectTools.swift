import Foundation
import MCP

enum ProjectTools {
    static func handle(_ params: CallTool.Parameters, client: PlanioClient) async throws -> CallTool.Result {
        let p = ToolParams(args: params.arguments)

        switch params.name {
        case "list_projects":
            return try await listProjects(p, client: client)
        default:
            return .init(content: [.text("Unknown project tool: \(params.name)")], isError: true)
        }
    }

    private static func listProjects(_ p: ToolParams, client: PlanioClient) async throws -> CallTool.Result {
        // If project_id given → single project with full details
        if let projectId = p.optionalString("project_id") {
            let response: ProjectResponse = try await client.get(
                path: "/projects/\(projectId)",
                queryParams: ["include": "trackers,issue_categories,enabled_modules,time_entry_activities"]
            )
            return .init(content: [.text(ResponseFormatter.formatProjectDetail(response.project))])
        }

        // Otherwise → list all
        var query: [String: String] = [:]
        if let limit = p.optionalInt("limit") { query["limit"] = String(limit) }
        if let offset = p.optionalInt("offset") { query["offset"] = String(offset) }

        let response: ProjectsResponse = try await client.get(
            path: "/projects",
            queryParams: query.isEmpty ? nil : query
        )
        return .init(content: [.text(ResponseFormatter.formatProjectList(response))])
    }
}
