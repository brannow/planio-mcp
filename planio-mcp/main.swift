//
//  main.swift
//  planio-mcp
//
//  Created by Benjamin Rannow on 10.03.26.
//

import Foundation
import MCP

// Load configuration
let config = try Config.load()
let features = config.features
let planioClient = PlanioClient(baseURL: config.baseURL, apiKey: config.apiKey)

// Create MCP server
let server = Server(
    name: "planio-mcp",
    version: "1.0.0",
    capabilities: .init(
        tools: .init(listChanged: false)
    )
)

// Register tool list handler
await server.withMethodHandler(ListTools.self) { _ in
    return .init(tools: ToolDefinitions.all(features: features))
}

// Register tool call handler
await server.withMethodHandler(CallTool.self) { params in
    do {
        switch params.name {
        // Issues
        case "list_issues", "get_issue", "create_issue", "update_issue",
             "delete_issue", "add_watcher", "remove_watcher", "bulk_get_issues":
            return try await IssueTools.handle(params, client: planioClient, server: server, features: features)

        // Time Entries
        case "list_time_entries", "get_time_entry", "create_time_entry",
             "update_time_entry", "delete_time_entry":
            return try await TimeEntryTools.handle(params, client: planioClient)

        // Projects
        case "list_projects":
            return try await ProjectTools.handle(params, client: planioClient)

        // Users
        case "get_current_user", "list_users":
            return try await UserTools.handle(params, client: planioClient)

        // Activity
        case "get_activity":
            return try await ActivityTools.handle(params, client: planioClient, server: server, features: features)

        default:
            return .init(content: [.text("Unknown tool: \(params.name)")], isError: true)
        }
    } catch let error as ToolError {
        return .init(content: [.text(error.localizedDescription)], isError: true)
    } catch {
        return .init(content: [.text("Error: \(error.localizedDescription)")], isError: true)
    }
}

// Start server with stdio transport
let transport = StdioTransport()
try await server.start(transport: transport)

// Keep alive
try await Task.sleep(for: .seconds(86400 * 365))
