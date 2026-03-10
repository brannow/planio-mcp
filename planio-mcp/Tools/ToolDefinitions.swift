import MCP

enum ToolDefinitions {
    static func all(features: Features) -> [Tool] {
        [
            // Issues
            listIssues,
            getIssue(features: features),
            createIssue(features: features),
            updateIssue(features: features),
            deleteIssue,
            addWatcher, removeWatcher,
            // Time Entries
            listTimeEntries, getTimeEntry, createTimeEntry, updateTimeEntry, deleteTimeEntry,
            // Projects
            listProjects,
            // Users
            getCurrentUser, listUsers,
            // Activity
            getActivity
        ]
    }

    // MARK: - Annotation Presets

    private static let readOnly = Tool.Annotations(
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true
    )

    private static let create = Tool.Annotations(
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: true
    )

    private static let update = Tool.Annotations(
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true
    )

    private static let destructive = Tool.Annotations(
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true
    )

    // MARK: - Issues

    static let listIssues = Tool(
        name: "list_issues",
        description: "List issues with filters. Supports filtering by project, status, assignee, tracker, dates, custom fields, and pagination. Use status_id='*' to include closed issues, 'open' for open only, 'closed' for closed only, or a numeric ID.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "project_id": prop("integer", "Filter by project ID"),
                "status_id": prop("string", "Filter by status: 'open', 'closed', '*' (all), or numeric status ID"),
                "assigned_to_id": prop("string", "Filter by assignee: numeric user ID or 'me'"),
                "tracker_id": prop("integer", "Filter by tracker ID"),
                "author_id": prop("integer", "Filter by author (creator) user ID"),
                "fixed_version_id": prop("integer", "Filter by target version/sprint ID"),
                "sort": prop("string", "Sort field, e.g. 'updated_on:desc', 'priority:desc', 'due_date'"),
                "created_on": prop("string", "Filter by creation date. Operators: '>=2024-01-01', '<=2024-12-31', '><2024-01-01|2024-03-31' (between)"),
                "updated_on": prop("string", "Filter by update date. Operators: '>=2024-01-01', '<=2024-12-31', '><2024-01-01|2024-03-31' (between)"),
                "limit": prop("integer", "Max results (default 25, max 100)"),
                "offset": prop("integer", "Pagination offset (default 0)")
            ])
        ]),
        annotations: readOnly
    )

    static func getIssue(features: Features) -> Tool {
        let includeDesc = features.checklists
            ? "Comma-separated associations to include: journals, children, attachments, relations, watchers, changesets. Use 'journals' to see checklists and change history. IMPORTANT: You MUST call this with include=journals before any checklist modification to get current item IDs."
            : "Comma-separated associations to include: journals, children, attachments, relations, watchers, changesets."
        let desc = features.checklists
            ? "Get detailed information about a single issue, including description, custom fields, and optionally journals (change history with checklists), children, attachments, relations, watchers, and changesets. The checklist section shows item IDs needed for checklist updates."
            : "Get detailed information about a single issue, including description, custom fields, and optionally journals (change history), children, attachments, relations, watchers, and changesets."
        return Tool(
            name: "get_issue",
            description: desc,
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("issue_id")]),
                "properties": .object([
                    "issue_id": prop("integer", "The issue ID"),
                    "include": prop("string", includeDesc)
                ])
            ]),
            annotations: readOnly
        )
    }

    static func createIssue(features: Features) -> Tool {
        var properties: [String: Value] = [
            "project_id": prop("integer", "Project ID (required)"),
            "subject": prop("string", "Issue title (required)"),
            "tracker_id": prop("integer", "Tracker ID (e.g. Bug, Feature, Task)"),
            "status_id": prop("integer", "Status ID"),
            "priority_id": prop("integer", "Priority ID"),
            "assigned_to_id": prop("integer", "Assignee user ID"),
            "parent_issue_id": prop("integer", "Parent issue ID (creates sub-task)"),
            "fixed_version_id": prop("integer", "Target version/sprint ID"),
            "category_id": prop("integer", "Issue category ID"),
            "description": prop("string", "Issue description (supports wiki/markdown syntax)"),
            "start_date": prop("string", "Start date (YYYY-MM-DD)"),
            "due_date": prop("string", "Due date (YYYY-MM-DD)"),
            "estimated_hours": prop("number", "Estimated hours"),
            "is_private": prop("boolean", "Whether the issue is private"),
            "custom_fields": .object(["type": .string("array"), "description": .string("Array of {id, value} objects for custom fields")]),
            "watcher_user_ids": .object(["type": .string("array"), "description": .string("Array of user IDs to add as watchers")])
        ]
        var desc = "Create a new issue. Returns the created issue with its ID. Use parent_issue_id to create sub-tasks."
        if features.checklists {
            properties["checklists_attributes"] = .object(["type": .string("object"), "description": .string("Checklist items as object. Each key must be unique (use 'new_0', 'new_1', 'new_2', etc.). Values: {subject: string, is_done: bool, position: int, is_section: bool}. position starts at 1. Example: {'new_0': {subject: 'First task', is_done: false, position: 1}, 'new_1': {subject: 'Second task', is_done: false, position: 2}}")])
            desc += " Supports checklists_attributes to add checklist items on creation."
        }
        return Tool(
            name: "create_issue",
            description: desc,
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("project_id"), .string("subject")]),
                "properties": .object(properties)
            ]),
            annotations: create
        )
    }

    static func updateIssue(features: Features) -> Tool {
        var properties: [String: Value] = [
            "issue_id": prop("integer", "The issue ID to update (required)"),
            "subject": prop("string", "New issue title"),
            "tracker_id": prop("integer", "New tracker ID"),
            "status_id": prop("integer", "New status ID"),
            "priority_id": prop("integer", "New priority ID"),
            "assigned_to_id": prop("string", "New assignee user ID, or empty string to unassign"),
            "parent_issue_id": prop("integer", "New parent issue ID"),
            "fixed_version_id": prop("integer", "New target version/sprint ID"),
            "category_id": prop("integer", "New category ID"),
            "description": prop("string", "New description"),
            "start_date": prop("string", "New start date (YYYY-MM-DD)"),
            "due_date": prop("string", "New due date (YYYY-MM-DD)"),
            "estimated_hours": prop("number", "New estimated hours"),
            "done_ratio": prop("integer", "Completion percentage (0-100)"),
            "is_private": prop("boolean", "Whether the issue is private"),
            "notes": prop("string", "Journal comment to add"),
            "custom_fields": .object(["type": .string("array"), "description": .string("Array of {id, value} objects")])
        ]
        var desc = "Update an existing issue. Only send the fields you want to change. Use 'notes' to add a journal comment."
        if features.checklists {
            properties["checklists_attributes"] = .object(["type": .string("object"), "description": .string("""
                Checklist operations as object. BEFORE modifying checklists, you MUST first call get_issue with include=journals to read current checklist item IDs. \
                Only include items you want to create, update, or delete — omitted items are left unchanged. \
                CREATE new item: use unique key like 'new_0', 'new_1'. Value: {subject: string, is_done: false, position: int}. \
                UPDATE existing item: use the item's numeric ID as key (e.g. '123'). Value: {id: 123, subject: string, is_done: bool, position: int}. Include id inside the value too. \
                DELETE item: use item ID as key. Value: {id: 123, _destroy: true}. \
                WARNING: Using a 'new_X' key for an item that already exists will create a DUPLICATE. Always use the existing numeric ID to update.
                """)])
            desc += " Supports checklists_attributes for checklist management — read the parameter description carefully to avoid duplicating items."
        }
        return Tool(
            name: "update_issue",
            description: desc,
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("issue_id")]),
                "properties": .object(properties)
            ]),
            annotations: update
        )
    }

    static let deleteIssue = Tool(
        name: "delete_issue",
        description: "Permanently delete an issue. This cannot be undone.",
        inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("issue_id")]),
            "properties": .object([
                "issue_id": prop("integer", "The issue ID to delete")
            ])
        ]),
        annotations: destructive
    )

    static let addWatcher = Tool(
        name: "add_watcher",
        description: "Add a user as a watcher to an issue. Watchers receive notifications about issue changes.",
        inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("issue_id"), .string("user_id")]),
            "properties": .object([
                "issue_id": prop("integer", "The issue ID"),
                "user_id": prop("integer", "The user ID to add as watcher")
            ])
        ]),
        annotations: update
    )

    static let removeWatcher = Tool(
        name: "remove_watcher",
        description: "Remove a user as a watcher from an issue.",
        inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("issue_id"), .string("user_id")]),
            "properties": .object([
                "issue_id": prop("integer", "The issue ID"),
                "user_id": prop("integer", "The user ID to remove as watcher")
            ])
        ]),
        annotations: update
    )

    // MARK: - Time Entries

    static let listTimeEntries = Tool(
        name: "list_time_entries",
        description: "List time entries with filters. Can filter by project, user, and date range.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "project_id": prop("integer", "Filter by project ID"),
                "user_id": prop("integer", "Filter by user ID"),
                "from": prop("string", "Start date filter (YYYY-MM-DD)"),
                "to": prop("string", "End date filter (YYYY-MM-DD)"),
                "limit": prop("integer", "Max results (default 25, max 100)"),
                "offset": prop("integer", "Pagination offset (default 0)")
            ])
        ]),
        annotations: readOnly
    )

    static let getTimeEntry = Tool(
        name: "get_time_entry",
        description: "Get detailed information about a single time entry.",
        inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("id")]),
            "properties": .object([
                "id": prop("integer", "The time entry ID")
            ])
        ]),
        annotations: readOnly
    )

    static let createTimeEntry = Tool(
        name: "create_time_entry",
        description: "Create a new time entry (book time). Requires either issue_id or project_id, plus hours and activity_id. Use spent_on for the date (defaults to today).",
        inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("hours"), .string("activity_id")]),
            "properties": .object([
                "issue_id": prop("integer", "Issue ID to book time against"),
                "project_id": prop("integer", "Project ID (alternative to issue_id)"),
                "hours": prop("number", "Hours spent (decimal, e.g. 1.5)"),
                "activity_id": prop("integer", "Activity type ID (e.g. 10 for Programmierung)"),
                "spent_on": prop("string", "Date (YYYY-MM-DD, defaults to today)"),
                "comments": prop("string", "Comment describing the work done (max 1024 chars)"),
                "custom_fields": .object(["type": .string("array"), "description": .string("Array of {id, value} objects")])
            ])
        ]),
        annotations: create
    )

    static let updateTimeEntry = Tool(
        name: "update_time_entry",
        description: "Update an existing time entry. Only send the fields you want to change.",
        inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("id")]),
            "properties": .object([
                "id": prop("integer", "The time entry ID to update"),
                "issue_id": prop("integer", "New issue ID"),
                "project_id": prop("integer", "New project ID"),
                "hours": prop("number", "New hours"),
                "activity_id": prop("integer", "New activity type ID"),
                "spent_on": prop("string", "New date (YYYY-MM-DD)"),
                "comments": prop("string", "New comment")
            ])
        ]),
        annotations: update
    )

    static let deleteTimeEntry = Tool(
        name: "delete_time_entry",
        description: "Delete a time entry. This cannot be undone.",
        inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("id")]),
            "properties": .object([
                "id": prop("integer", "The time entry ID to delete")
            ])
        ]),
        annotations: destructive
    )

    // MARK: - Projects

    static let listProjects = Tool(
        name: "list_projects",
        description: "List all projects, or get full details for a single project. Without project_id: returns all accessible projects with IDs, names, identifiers. With project_id: returns full project details including trackers, issue categories, time entry activities, and enabled modules — use this to discover IDs needed for creating issues and booking time.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "project_id": prop("string", "Project ID or identifier string. If provided, returns full details for this project instead of listing all."),
                "limit": prop("integer", "Max results when listing (default 25, max 100)"),
                "offset": prop("integer", "Pagination offset when listing (default 0)")
            ])
        ]),
        annotations: readOnly
    )

    // MARK: - Users

    static let getCurrentUser = Tool(
        name: "get_current_user",
        description: "Get information about the currently authenticated user, including their ID, name, email, and login.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:])
        ]),
        annotations: readOnly
    )

    static let listUsers = Tool(
        name: "list_users",
        description: "List users. Can filter by status or search by name. Requires admin privileges for full list.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "status": prop("string", "Filter by status: 'active', 'registered', 'locked'"),
                "name": prop("string", "Search by name or login"),
                "limit": prop("integer", "Max results (default 25, max 100)"),
                "offset": prop("integer", "Pagination offset (default 0)")
            ])
        ]),
        annotations: readOnly
    )

    // MARK: - Activity

    static let getActivity = Tool(
        name: "get_activity",
        description: "Activity log for a user. Returns a plain list of tickets the user touched in the date range, grouped by ticket with dates nested underneath. Each date shows actions (comments, status changes, reassignments, field updates) and booked hours. Use this to answer: 'What did I work on?', 'Show me my activity log', 'What tickets did I touch last week?'. The total booked hours for the period are shown at the top. WARNING: This tool scans all updated issues in the date range and fetches journals for each one. Large date ranges (>2 weeks) or high-traffic projects can result in hundreds of API calls and take 10-30+ seconds. Prefer short date ranges (1-2 weeks) and filter by project_id when possible.",
        inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("from")]),
            "properties": .object([
                "from": prop("string", "Start date (YYYY-MM-DD, required)"),
                "to": prop("string", "End date (YYYY-MM-DD, defaults to today)"),
                "user_id": prop("integer", "User ID (defaults to current user if omitted)"),
                "project_id": prop("integer", "Filter by project ID (omit for all projects)")
            ])
        ]),
        annotations: readOnly
    )

    // MARK: - Helper

    private static func prop(_ type: String, _ description: String) -> Value {
        .object([
            "type": .string(type),
            "description": .string(description)
        ])
    }
}
