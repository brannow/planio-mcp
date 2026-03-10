# planio-mcp

MCP server for [Redmine](https://www.redmine.org/) / [Planio](https://plan.io). Full read/write access to issues, time entries, projects, and users via the standard Redmine REST API.

Compatible with **any Redmine instance**. Planio-specific features (checklists) are opt-in via feature flags.

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
| `list_issues` | Filter by project, status, assignee, tracker, dates, custom fields |
| `get_issue` | Full details + journals, attachments, relations, watchers, checklists |
| `create_issue` | Create with sub-tasks, custom fields, watchers, checklists |
| `update_issue` | Update fields, add comments (`notes`), manage checklists |
| `delete_issue` | Permanently delete |
| `add_watcher` | Add watcher to issue |
| `remove_watcher` | Remove watcher from issue |

### Time Entries

| Tool | Description |
|------|-------------|
| `list_time_entries` | Filter by project, user, date range |
| `get_time_entry` | Single entry details |
| `create_time_entry` | Book time against issue or project |
| `update_time_entry` | Modify existing entry |
| `delete_time_entry` | Delete entry |

### Projects & Users

| Tool | Description |
|------|-------------|
| `list_projects` | List all, or get single project with trackers/categories/activities |
| `get_current_user` | Current authenticated user |
| `list_users` | Search/filter users (admin required for full list) |

### Activity

| Tool | Description |
|------|-------------|
| `get_activity` | User activity log over a date range. Combines time entries + journal scan. Grouped by issue with actions and booked hours. |

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
Book 2h on #1234, activity Programmierung, comment "API refactoring"
```

```
Create a bug "Login broken on Safari" in project 5, priority high, assign to user 12
```

```
Show me all open issues assigned to me, sorted by priority
```

```
Show me project 5 with all trackers and time entry activities
```

## Architecture

```
planio-mcp/
├── main.swift                 # Server setup, tool routing
├── Config.swift               # .env parsing, feature flags
├── PlanioClient.swift         # HTTP client (actor, 5min issue cache)
├── Models/
│   ├── Issue.swift            # Issue, Journal, Checklist, Relations
│   ├── TimeEntry.swift
│   ├── Project.swift
│   └── User.swift
├── Tools/
│   ├── ToolDefinitions.swift  # JSON Schema definitions (feature-aware)
│   ├── IssueTools.swift
│   ├── TimeEntryTools.swift
│   ├── ProjectTools.swift
│   ├── UserTools.swift
│   └── ActivityTools.swift    # Composite activity log
└── Helpers/
    ├── ValueHelpers.swift     # MCP Value extraction
    └── ResponseFormatter.swift
```

## Notes

- **Redmine compatible** — all endpoints are standard Redmine REST API
- **Auth:** `X-Redmine-API-Key` header
- **Issue cache:** 5-minute in-memory TTL, auto-invalidated on writes
- **`get_activity`:** Parallel journal fetching (10 concurrent) with progress notifications
- **Swift 5 / macOS** — uses [mcp-swift-sdk](https://github.com/modelcontextprotocol/swift-sdk)
