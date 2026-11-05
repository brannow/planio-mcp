# planio-mcp

[MCP](https://modelcontextprotocol.io) server that lets AI agents (Claude Code, Claude Desktop, …) work with [Planio](https://plan.io) / [Redmine](https://www.redmine.org/): issues, attachments, time entries, projects, users. Works with any Redmine instance via the standard REST API.

**Requirements:** macOS 26.2+, Apple Silicon. A Redmine/Planio API key (Avatar → My account → sidebar → *Show API key*).

## Install

```bash
curl -fsSL https://github.com/brannow/planio-mcp/releases/latest/download/planio-mcp-macos-arm64.tar.gz | tar -xz
sudo mkdir -p /usr/local/bin && sudo mv planio-mcp /usr/local/bin/
planio-mcp --version
```

The binary is ad-hoc signed, not notarized. Downloaded via a browser instead of `curl`, macOS will block it; clear the flag once with `xattr -d com.apple.quarantine planio-mcp`.

## Configure

| Variable | Required | Description |
|----------|----------|-------------|
| `TICKET_URL` | yes | e.g. `https://your-instance.plan.io` |
| `TICKET_KEY` | yes | your API key |
| `FEATURE_CHECKLISTS` | no | `true` enables checklist support (Planio or [Redmine Checklists plugin](https://www.redmineup.com/pages/plugins/checklists)); off = parameters are hidden from the agent |

Set them as environment variables (highest priority) or in a `.env` file: next to the binary, in the working directory, or via `planio-mcp --env /path/to/.env`. See [`.env.example`](.env.example).

## Connect

**Claude Code**

```bash
claude mcp add planio -s user \
  -e TICKET_URL=https://your-instance.plan.io -e TICKET_KEY=your-api-key \
  -- /usr/local/bin/planio-mcp
```

**Claude Desktop / other clients** (`claude_desktop_config.json` or equivalent)

```json
{
  "mcpServers": {
    "planio": {
      "command": "/usr/local/bin/planio-mcp",
      "env": { "TICKET_URL": "https://your-instance.plan.io", "TICKET_KEY": "your-api-key" }
    }
  }
}
```

Test without a client: `npx @modelcontextprotocol/inspector /usr/local/bin/planio-mcp`

## Tools

| Area | Tools |
|------|-------|
| Issues | `list_issues`, `get_issue`, `get_issue_tree` (epic + sub-issues + time rollups), `bulk_get_issues`, `create_issue`, `update_issue` (fields, comments, private notes, checklists), `delete_issue`, `add_watcher`, `remove_watcher` |
| Attachments | `download_attachments` (to `$TMPDIR/planio-mcp/<issue>/`), `upload_attachments`, `update_attachment`, `delete_attachment` |
| Time entries | `list_time_entries` (defaults to you, auto-paginates up to 500), `get_time_entry`, `create_time_entry`, `update_time_entry`, `delete_time_entry` |
| Projects & users | `list_projects`, `get_current_user`, `list_users` |
| Activity | `get_activity` (what a user did over a date range, grouped by issue with booked hours) |

Behavior worth knowing:

- **Names instead of IDs:** tracker, status, priority, category, version, activity and assignee accept names (`"Bug"`, `"High"`, `"John"`) or IDs; `project_id` accepts IDs or identifiers. On a mismatch the error lists the valid options.
- **Caching:** issues and metadata are cached in memory for 5 minutes and invalidated on writes.
- **Private notes:** a new comment can be private, but an existing comment can't be switched (Planio returns 403 for API keys). A private note combined with field changes becomes two journal entries.

## Build from source

```bash
xcodebuild -project planio-mcp.xcodeproj -scheme planio-mcp -configuration Release \
  -derivedDataPath build build
# -> build/Build/Products/Release/planio-mcp
```

Xcode 27+ (Swift 6.4). Code lives in `planio-mcp/`: `main.swift` (tool routing), `PlanioClient.swift` (HTTP + cache), `Tools/` (one file per area), `Tools/ToolDefinitions.swift` (JSON schemas).

## Release

1. Bump `appVersion` in `planio-mcp/Version.swift` and commit.
2. `git tag vX.Y.Z && git push origin vX.Y.Z`

[`.github/workflows/release.yml`](.github/workflows/release.yml) builds, signs, smoke-tests and publishes the release. It fails if the tag doesn't match `appVersion`. Run it manually (*Actions → Release → Run workflow*) to get a test build without publishing.

## License

[MIT](LICENSE)
