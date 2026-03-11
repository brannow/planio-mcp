# planio-mcp

MCP server for [Redmine](https://www.redmine.org/) / [Planio](https://plan.io). Full read/write access to issues, time entries, projects, and users via the standard Redmine REST API.

Compatible with **any Redmine instance**. Planio-specific features (checklists) are opt-in via feature flags.

## Design Philosophy

This server is an **intent interface**, not an API proxy. The agent says *what it wants* — the server figures out *how*.

- **Name resolution** — `tracker_id: "Bug"`, `priority_id: "High"`, `activity_id: "Development"` just work. The server resolves names to IDs internally. On mismatch, it returns the valid options so the agent self-corrects.
- **Project identifiers** — `project_id` accepts both numeric IDs (`5`) and Redmine identifiers (`"my-project"`) across all tools.
- **Contextual feedback** — Booking time returns the issue's time budget. Overdue issues show warnings. The agent doesn't need follow-up calls to understand the situation.
- **Backward compatible** — Numeric IDs still work everywhere. Clients sending `{"tracker_id": 3}` as int or `"3"` as string are both handled.

## Setup

### 1. Build

```bash
xcodebuild -scheme planio-mcp -configuration Release build
```

Or open in Xcode and `Cmd+B`.

### 2. Configure

```env
# Required
TICKET_URL=https://your-instance.plan.io
TICKET_KEY=your-api-key-here

# Feature flags (opt-in, default: false)
FEATURE_CHECKLISTS=true
```

Place as `.env` next to the binary, in the working directory, or pass via environment variables.
You can also specify a custom path: `planio-mcp --env /path/to/.env`

**Config priority:** `ENV vars` > `.env file`

**API key:** Redmine/Planio → Your Avatar → My account → Sidebar → Show API Key

### 3. Connect

#### Claude Desktop / Claude Code

Add to your MCP config (`claude_desktop_config.json` or `.claude/settings.json`):

```json
{
  "mcpServers": {
    "redmine": {
      "command": "/absolute/path/to/planio-mcp",
      "env": {
        "TICKET_URL": "https://your-instance.plan.io",
        "TICKET_KEY": "your-api-key-here",
        "FEATURE_CHECKLISTS": "true"
      }
    }
  }
}
```

#### MCP Inspector (testing)

```bash
npx @modelcontextprotocol/inspector /absolute/path/to/planio-mcp
```

## Tools

### Issues

| Tool | Description |
|------|-------------|
| `list_issues` | Filter by project (ID or identifier), status, assignee, tracker, dates, custom fields. Tracker and version accept names. |
| `get_issue` | Full details with section filtering (`sections` param). Includes due date warnings for overdue issues. |
| `bulk_get_issues` | Fetch multiple issues in parallel with progress notifications. Same filtering as `get_issue`. |
| `create_issue` | Create with all fields. Tracker, status, priority, category, version, and assignee accept names — the server resolves them. |
| `update_issue` | Update fields, add comments (`notes`), manage checklists. Same name resolution as create. |
| `delete_issue` | Permanently delete |
| `add_watcher` | Add watcher to issue |
| `remove_watcher` | Remove watcher from issue |

### Time Entries

| Tool | Description |
|------|-------------|
| `list_time_entries` | Filter by project, issue, user, date range |
| `get_time_entry` | Single entry details |
| `create_time_entry` | Book time against issue or project. Activity accepts names. Returns time budget context (spent vs estimated). |
| `update_time_entry` | Modify existing entry. Activity accepts names. |
| `delete_time_entry` | Delete entry |

### Projects & Users

| Tool | Description |
|------|-------------|
| `list_projects` | List all, or get single project with trackers, categories, activities, versions, and modules |
| `get_current_user` | Current authenticated user |
| `list_users` | Search/filter users (admin required for full list) |

### Activity

| Tool | Description |
|------|-------------|
| `get_activity` | User activity log over a date range. Combines time entries + journal scan. Grouped by issue with actions, booked hours, and time budget per ticket. |

## Name Resolution

All resolvable fields accept either a **name** (string) or a **numeric ID**. The server resolves names via cached metadata.

| Field | Example values | Scope |
|-------|---------------|-------|
| `tracker_id` | `"Bug"`, `"Feature"`, `1` | Project-scoped (falls back to global) |
| `status_id` | `"New"`, `"In Progress"`, `"Closed"` | Global |
| `priority_id` | `"Normal"`, `"High"`, `"Urgent"` | Global |
| `category_id` | `"Backend"`, `"Frontend"` | Project-scoped (requires `project_id`) |
| `fixed_version_id` | `"Sprint 12"`, `"v2.0"` | Project-scoped (requires `project_id`) |
| `activity_id` | `"Development"`, `"Support"` | Project-scoped (requires project context) |
| `assigned_to_id` | `"John"`, `"jane.doe"`, `42` | User search (`/users.json?name=X`) |

On mismatch, the error message lists all valid options:

```
No tracker named 'Defect'. Available: Bug, Feature, Support, Task
```

## Contextual Feedback

The server enriches responses with actionable context so the agent doesn't need follow-up calls:

- **Time budget on booking** — After `create_time_entry`, the response includes `Issue #4523 time: 23.0h of 30.0h`
- **Time budget in activity logs** — `get_activity` shows `#4523: Fix auth flow (23.0h of 30.0h)` per ticket
- **Due date warnings** — `get_issue` and `list_issues` show warnings for non-closed issues:
  - `⚠ OVERDUE by 5 days (due 2026-03-06)`
  - `⚠ Due today (2026-03-11)`
  - `⚠ Due in 2 days (2026-03-13)`

## Feature Flags

| Flag | Default | Description |
|------|---------|-------------|
| `FEATURE_CHECKLISTS` | `false` | Checklist support (requires [Redmine Checklists plugin](https://www.redmineup.com/pages/plugins/checklists) or Planio). Adds checklist parameters to create/update tools, shows checklist items with IDs in issue output. |

When a feature flag is off, the corresponding parameters are **removed from tool schemas** — the LLM never sees them.

## Prompt Examples

```
What did I work on last week?
```

```
Book 2h on #1234, activity Development, comment "API refactoring"
```

```
Create a bug "Login broken on Safari" in project my-project, priority High, assign to John
```

```
Show me all open issues assigned to me, sorted by priority
```

```
Update #1234 status to "In Progress" and assign to me
```

```
List all Feature issues in Sprint 12
```

## Architecture

```
planio-mcp/
├── main.swift                 # Server setup, tool routing
├── Config.swift               # .env parsing, feature flags
├── PlanioClient.swift         # HTTP client (actor, cached metadata + issues)
├── Models/
│   ├── Issue.swift            # Issue, Journal, Checklist, Relations, shared types
│   ├── IssueFilterOptions.swift # Section filtering for get_issue output
│   ├── MetadataResponses.swift  # Statuses, Priorities, Trackers response models
│   ├── TimeEntry.swift
│   ├── Project.swift
│   └── User.swift
├── Tools/
│   ├── ToolDefinitions.swift  # JSON Schema definitions (feature-aware)
│   ├── IssueTools.swift       # CRUD + watchers + name resolution
│   ├── TimeEntryTools.swift   # CRUD + activity resolution + time budget
│   ├── ProjectTools.swift
│   ├── UserTools.swift
│   └── ActivityTools.swift    # Composite activity log with time budget per ticket
└── Helpers/
    ├── NameResolver.swift     # Name-to-ID resolution with guided errors
    ├── ValueHelpers.swift     # MCP Value extraction, type-flexible param reading
    └── ResponseFormatter.swift # Output formatting, due date warnings
```

## Notes

- **Redmine compatible** — all endpoints are standard Redmine REST API
- **Auth:** `X-Redmine-API-Key` header
- **Caching:** 5-minute in-memory TTL for issues and metadata (statuses, priorities, trackers, per-project metadata). Auto-invalidated on writes. Bulk fetches (`get_activity`, `bulk_get_issues`) skip already-cached issues — repeat calls within TTL are near-instant.
- **Parallel fetching:** `get_activity` and `bulk_get_issues` use cache-aware bulk loading (10 concurrent) with progress notifications.
- **Swift 5 / macOS** — uses [mcp-swift-sdk](https://github.com/modelcontextprotocol/swift-sdk)
