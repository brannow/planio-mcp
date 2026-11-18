import Foundation
import MCP

/// get_changes: "what happened since X?" as one compact block per ticket.
/// Replaces the agent's own list_issues + bulk_get_issues + filtering loop.
enum ChangeTools {

    static func handle(_ params: CallTool.Parameters, client: PlanioClient, server: Server?) async throws -> CallTool.Result {
        let p = ToolParams(args: params.arguments)
        let sinceRaw = try p.requireString("since")
        let since = DateText.normalizeSince(sinceRaw)
        let project = p.optionalStringOrInt("project_id").flatMap { $0.isEmpty ? nil : $0 }
        let maxIssues = min(max(p.optionalInt("limit") ?? 50, 1), 200)
        let allFields = p.optionalBool("include_field_changes") ?? true

        // 1. Issues touched since `since` (any status — closing is a change too)
        var query: [String: String] = [
            "updated_on": ">=\(since)",
            "sort": "updated_on:desc",
            "limit": "100"
        ]
        if let project { query["project_id"] = project }
        let status = try await IssueTools.resolveStatusFilter(p.optionalStringOrInt("status_id") ?? "*", client: client)
        query["status_id"] = status.query
        if let assignee = p.optionalStringOrInt("assigned_to_id"), !assignee.isEmpty {
            query["assigned_to_id"] = ["me", "*", "!*"].contains(assignee.lowercased()) || Int(assignee) != nil
                ? assignee.lowercased()
                : String(try await NameResolver.resolveUser(assignee, project: project, client: client))
        }

        var listed: [Issue] = []
        var totalCount = 0
        while listed.count < maxIssues {
            query["offset"] = String(listed.count)
            let page: IssuesResponse = try await client.get(path: "/issues", queryParams: query)
            totalCount = page.totalCount
            listed.append(contentsOf: page.issues)
            if page.issues.isEmpty || listed.count >= page.totalCount { break }
        }
        listed = Array(listed.prefix(maxIssues))

        if listed.isEmpty {
            return .init(content: [.text("No issues changed since \(since)\(project.map { " in project \($0)" } ?? "") (status filter: \(status.label)).")])
        }

        // 2. Full details incl. journals. Drop cache entries older than the list's
        //    updated_on first, otherwise the last few minutes of changes are missed.
        for issue in listed { await client.invalidateIfStale(id: issue.id, updatedOn: issue.updatedOn) }
        let progressToken = params._meta?.progressToken
        let data = try await client.getIssues(ids: listed.map(\.id), concurrency: 10) { done, total in
            guard let server, let token = progressToken, done % 10 == 0 || done == total else { return }
            try? await server.notify(ProgressNotification.message(
                .init(progressToken: token, progress: Double(done), total: Double(total), message: "Loaded \(done) of \(total) issues")))
        }
        let decoder = JSONDecoder()
        let issues: [Issue] = listed.compactMap { row in
            data[row.id].flatMap { try? decoder.decode(IssueResponse.self, from: $0).issue } ?? row
        }
        let lookup = await NameLookup.build(for: issues, client: client)

        // 3. Render
        var blocks: [String] = []
        var newCount = 0, closedCount = 0
        for issue in issues {
            var block: [String] = []
            var head = "#\(issue.id) [\(issue.status?.name ?? "?")] \(issue.subject?.sanitized ?? "")"
            var meta: [String] = []
            if let a = issue.assignedTo?.name { meta.append("@\(a)") }
            if project == nil, let pr = issue.project?.name { meta.append(pr) }
            if !meta.isEmpty { head += " — " + meta.joined(separator: ", ") }
            block.append(head)

            if let created = issue.createdOn, created >= since {
                newCount += 1
                block.append("  NEW \(time(created)) by \(issue.author?.name ?? "?")")
            }
            if let closed = issue.closedOn, closed >= since {
                closedCount += 1
                block.append("  CLOSED \(time(closed))")
            }

            let journals = (issue.journals ?? []).filter { ($0.createdOn ?? "") >= since }
            var shown = 0
            for j in journals {
                var parts: [String] = []
                var checklist = false
                for d in j.details ?? [] {
                    if d.name == "checklist" { checklist = true; continue }
                    // Compact mode keeps who/what-state changes, drops the rest
                    if !allFields, !(d.property == "attr" && ["status_id", "assigned_to_id"].contains(d.name ?? "")) { continue }
                    if let first = JournalRenderer.describe(d, issue: issue, lookup: lookup, diffLines: nil).first {
                        parts.append(first)
                    }
                }
                if checklist && allFields { parts.append("Checklist updated") }
                if let notes = j.notes, !notes.isEmpty {
                    let clean = notes.sanitized
                    parts.append("\"\(clean.prefix(200))\(clean.count > 200 ? "…" : "")\"")
                }
                guard !parts.isEmpty else { continue }
                let who = j.user?.name ?? "?"
                let priv = j.privateNotes == true ? " [private]" : ""
                block.append("  \(time(j.createdOn ?? "")) \(who)\(priv): " + parts.joined(separator: "; "))
                shown += 1
            }
            let isNew = issue.createdOn.map { $0 >= since } ?? false
            if shown == 0 && !isNew {
                if journals.isEmpty {
                    // Matched the updated_on filter but nothing visible to us changed
                    block.append("  (updated, but no visible journal entry — e.g. a private note you can't see, time booked, or a sub-issue change)")
                } else {
                    block.append("  (\(journals.count) other field change\(journals.count == 1 ? "" : "s") hidden — pass include_field_changes=true)")
                }
            }
            blocks.append(block.joined(separator: "\n"))
        }

        var header = ["# Changes since \(since)\(project.map { " — project \($0)" } ?? "")"]
        header.append("\(issues.count) issues changed (\(newCount) new, \(closedCount) closed), newest first. Times in \(TimeZone.current.identifier).")
        if status.label != "*" { header.append("Status filter (current status): \(status.label)") }
        if totalCount > issues.count {
            header.append("⚠ Showing \(issues.count) of \(totalCount) changed issues — narrow with project_id/status_id/assigned_to_id or a later since, or raise limit (max 200).")
        }
        header.append("Use get_issue (journals_since=\(since)) for full text of a ticket.")
        return .init(content: [.text(header.joined(separator: "\n") + "\n\n" + blocks.joined(separator: "\n\n"))])
    }

    /// "2026-11-17T13:02:00Z" -> "11-17 14:02" in local time
    private static func time(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: iso) else { return iso }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        f.timeZone = .current
        return f.string(from: date)
    }
}
