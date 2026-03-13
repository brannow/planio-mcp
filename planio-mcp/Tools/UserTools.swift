import Foundation
import MCP

enum UserTools {
    static func handle(_ params: CallTool.Parameters, client: PlanioClient) async throws -> CallTool.Result {
        let p = ToolParams(args: params.arguments)

        switch params.name {
        case "get_current_user":
            return try await getCurrentUser(client: client)
        case "list_users":
            return try await listUsers(p, client: client)
        default:
            return .init(content: [.text("Unknown user tool: \(params.name)")], isError: true)
        }
    }

    private static func getCurrentUser(client: PlanioClient) async throws -> CallTool.Result {
        let user = try await client.getCurrentUser()
        return .init(content: [.text(ResponseFormatter.formatUserDetail(user))])
    }

    private static func listUsers(_ p: ToolParams, client: PlanioClient) async throws -> CallTool.Result {
        var query: [String: String] = [:]
        if let status = p.optionalString("status") { query["status"] = status }
        if let name = p.optionalString("name") { query["name"] = name }
        if let limit = p.optionalInt("limit") { query["limit"] = String(limit) }
        if let offset = p.optionalInt("offset") { query["offset"] = String(offset) }

        let response: UsersResponse = try await client.get(
            path: "/users",
            queryParams: query.isEmpty ? nil : query
        )
        return .init(content: [.text(ResponseFormatter.formatUserList(response))])
    }
}
