import MCP

enum ToolDefinitions {
    static func all(features: Features) -> [Tool] {
        [
            // Issues
            listIssues,
            getIssue(features: features),
            bulkGetIssues(features: features),
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
        description: "List issues. Returns open issues by default. Use status_id to include closed ('closed') or all ('*').",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "project_id": prop("string", "Project ID or identifier (e.g. 'my-project')"),
                "status_id": prop("string", "Status filter: 'open' (default), 'closed', '*' (all)"),
                "assigned_to_id": prop("string", "Filter by assignee: user ID or 'me'"),
                "tracker_id": prop("string", "Tracker name or ID (e.g. 'Bug', 'Feature')"),
                "author_id": prop("integer", "Filter by author (creator) user ID"),
                "fixed_version_id": prop("string", "Version/sprint name or ID"),
                "sort": prop("string", "Sort field, e.g. 'updated_on:desc', 'priority:desc', 'due_date'"),
                "created_on": prop("string", "Filter by creation date: >=YYYY-MM-DD, <=YYYY-MM-DD, or ><YYYY-MM-DD|YYYY-MM-DD (between)"),
                "updated_on": prop("string", "Filter by update date. Same syntax as created_on."),
                "limit": prop("integer", "Max results (default 25, max 100)"),
                "offset": prop("integer", "Pagination offset (default 0)")
            ])
        ]),
        annotations: readOnly
    )

    static func getIssue(features: Features) -> Tool {
        var desc = "Get issue details. Use 'sections' to control output — omit for everything, use 'metadata' for just core fields."
        if features.checklists {
            desc += " Checklists are shown in the journals section — include 'journals' in sections to see checklist item IDs before modifying them."
        }
        return Tool(
            name: "get_issue",
            description: desc,
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("issue_id")]),
                "properties": .object([
                    "issue_id": prop("integer", "The issue ID"),
                    "sections": prop("string", "Comma-separated sections to include: description, custom_fields, journals, children, attachments, relations, watchers, changesets, hours, dates. Use 'metadata' for core fields only. Omit for full output."),
                    "journals_limit": prop("integer", "Max journal entries to return (default 10, from most recent)"),
                    "journals_since": prop("string", "Only show journals after this date (YYYY-MM-DD)")
                ])
            ]),
            annotations: readOnly
        )
    }

    static func bulkGetIssues(features: Features) -> Tool {
        Tool(
            name: "bulk_get_issues",
            description: "Get details for multiple issues at once. Same filtering as get_issue applies to all issues. Prefer this over multiple get_issue calls.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("issue_ids")]),
                "properties": .object([
                    "issue_ids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("integer")]),
                        "description": .string("Array of issue IDs")
                    ]),
                    "sections": prop("string", "Comma-separated sections to include (see get_issue). Omit for full output."),
                    "journals_limit": prop("integer", "Max journal entries per issue (default 10)"),
                    "journals_since": prop("string", "Only show journals after this date (YYYY-MM-DD)")
                ])
            ]),
            annotations: readOnly
        )
    }

    static func createIssue(features: Features) -> Tool {
        var properties: [String: Value] = [
            "project_id": prop("string", "Project ID or identifier (required, e.g. 'my-project')"),
            "subject": prop("string", "Issue title (required)"),
            "tracker_id": prop("string", "Tracker name or ID (e.g. 'Bug', 'Feature')"),
            "status_id": prop("string", "Status name or ID (e.g. 'New', 'In Progress')"),
            "priority_id": prop("string", "Priority name or ID (e.g. 'Normal', 'High')"),
            "assigned_to_id": prop("string", "Assignee name or user ID"),
            "parent_issue_id": prop("integer", "Parent issue ID (creates sub-task)"),
            "fixed_version_id": prop("string", "Version/sprint name or ID"),
            "category_id": prop("string", "Category name or ID"),
            "description": prop("string", "Issue description (supports textile/markdown)"),
            "start_date": prop("string", "Start date (YYYY-MM-DD)"),
            "due_date": prop("string", "Due date (YYYY-MM-DD)"),
            "estimated_hours": prop("number", "Estimated hours"),
            "is_private": prop("boolean", "Whether the issue is private"),
            "custom_fields": .object(["type": .string("array"), "description": .string("Array of {id, value} objects for custom fields")]),
            "watcher_user_ids": .object(["type": .string("array"), "description": .string("Array of user IDs to add as watchers")])
        ]
        var desc = "Create a new issue. Tracker, status, priority, category, version, and assignee accept names (e.g. 'Bug', 'High') — the server resolves them. On mismatch, available options are returned."
        if features.checklists {
            properties["checklists_attributes"] = .object(["type": .string("object"), "description": .string("Checklist items as object. Each key must be unique (use 'new_0', 'new_1', etc.). Values: {subject: string, is_done: bool, position: int}. position starts at 1.")])
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
            "tracker_id": prop("string", "Tracker name or ID (e.g. 'Bug', 'Feature')"),
            "status_id": prop("string", "Status name or ID (e.g. 'New', 'In Progress')"),
            "priority_id": prop("string", "Priority name or ID (e.g. 'Normal', 'High')"),
            "assigned_to_id": prop("string", "Assignee name or user ID, or empty string to unassign"),
            "parent_issue_id": prop("integer", "New parent issue ID"),
            "fixed_version_id": prop("string", "Version/sprint name or ID"),
            "category_id": prop("string", "Category name or ID"),
            "description": prop("string", "New description"),
            "start_date": prop("string", "New start date (YYYY-MM-DD)"),
            "due_date": prop("string", "New due date (YYYY-MM-DD)"),
            "estimated_hours": prop("number", "New estimated hours"),
            "done_ratio": prop("integer", "Completion percentage (0-100)"),
            "is_private": prop("boolean", "Whether the issue is private"),
            "notes": prop("string", "Add a comment to the issue journal"),
            "custom_fields": .object(["type": .string("array"), "description": .string("Array of {id, value} objects")])
        ]
        var desc = "Update an existing issue. Only send the fields you want to change. Tracker, status, priority, category, version, and assignee accept names — the server resolves them."
        if features.checklists {
            properties["checklists_attributes"] = .object(["type": .string("object"), "description": .string("""
                Checklist operations. First call get_issue with sections=journals to read current checklist item IDs. \
                Only include items you want to create, update, or delete — omitted items are left unchanged. \
                CREATE: key='new_0'. Value: {subject: string, is_done: false, position: int}. \
                UPDATE: key=item ID (e.g. '123'). Value: {id: 123, subject: string, is_done: bool}. \
                DELETE: key=item ID. Value: {id: 123, _destroy: true}. \
                WARNING: Using 'new_X' for an existing item creates a DUPLICATE — always use the numeric ID.
                """)])
            desc += " Supports checklists_attributes — read current checklist via get_issue first to avoid duplicates."
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
        description: "List booked time entries for the current user. Filter by project, issue, or date range. Defaults to current user — pass user_id only to see another user's entries. Automatically paginates (up to 500 entries).",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "project_id": prop("string", "Project ID or identifier (e.g. 'my-project')"),
                "issue_id": prop("integer", "Filter by issue ID"),
                "user_id": prop("integer", "Filter by user ID"),
                "from": prop("string", "Start date (YYYY-MM-DD)"),
                "to": prop("string", "End date (YYYY-MM-DD)")
            ])
        ]),
        annotations: readOnly
    )

    static let getTimeEntry = Tool(
        name: "get_time_entry",
        description: "Get details of a single time entry.",
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
        description: "Book time against an issue or project. Activity accepts a name (e.g. 'Development') — the server resolves it.",
        inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("hours"), .string("activity_id")]),
            "properties": .object([
                "issue_id": prop("integer", "Issue ID to book time against"),
                "project_id": prop("string", "Project ID or identifier (alternative to issue_id)"),
                "hours": prop("number", "Hours spent (decimal, e.g. 1.5)"),
                "activity_id": prop("string", "Activity name or ID (e.g. 'Development')"),
                "spent_on": prop("string", "Date (YYYY-MM-DD, defaults to today)"),
                "comments": prop("string", "Description of work done"),
                "custom_fields": .object(["type": .string("array"), "description": .string("Array of {id, value} objects")])
            ])
        ]),
        annotations: create
    )

    static let updateTimeEntry = Tool(
        name: "update_time_entry",
        description: "Update an existing time entry. Only send the fields you want to change. Activity accepts a name (e.g. 'Development') — the server resolves it.",
        inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("id")]),
            "properties": .object([
                "id": prop("integer", "The time entry ID to update"),
                "issue_id": prop("integer", "New issue ID"),
                "project_id": prop("string", "Project ID or identifier"),
                "hours": prop("number", "New hours"),
                "activity_id": prop("string", "Activity name or ID (e.g. 'Development')"),
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
        description: "List all projects, or get full details for a single project. With project_id: returns trackers, issue categories, time entry activities, versions, and enabled modules.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "project_id": prop("string", "Project ID or identifier. If provided, returns full project details instead of listing all."),
                "limit": prop("integer", "Max results when listing (default 25, max 100)"),
                "offset": prop("integer", "Pagination offset when listing (default 0)")
            ])
        ]),
        annotations: readOnly
    )

    // MARK: - Users

    static let getCurrentUser = Tool(
        name: "get_current_user",
        description: "Get the currently authenticated user's ID, name, email, and login.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:])
        ]),
        annotations: readOnly
    )

    static let listUsers = Tool(
        name: "list_users",
        description: "Search for users by name or list all users. Requires admin privileges for full list.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "status": prop("string", "Filter by status: 'active' (default), 'registered', 'locked'"),
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
        description: "Activity log for a user. Shows which tickets were touched in a date range, with actions (comments, status changes, field updates) and booked hours per day. Answers: 'What did I work on?', 'Show my activity last week'. Large date ranges (>2 weeks) may be slow — prefer shorter ranges and filter by project_id when possible.",
        inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("from")]),
            "properties": .object([
                "from": prop("string", "Start date (YYYY-MM-DD, required)"),
                "to": prop("string", "End date (YYYY-MM-DD, defaults to today)"),
                "user_id": prop("integer", "User ID (defaults to current user)"),
                "project_id": prop("string", "Project ID or identifier (e.g. 'my-project')")
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
