import Foundation

enum ResponseFormatter {

    // MARK: - Issues

    static func formatIssueList(_ response: IssuesResponse) -> String {
        var lines: [String] = []
        lines.append("Issues (\(response.totalCount) total, showing \(response.offset + 1)-\(response.offset + response.issues.count)):")
        lines.append("")

        for issue in response.issues {
            lines.append(formatIssueSummary(issue))
        }

        if response.totalCount > response.offset + response.issues.count {
            lines.append("")
            lines.append("Use offset=\(response.offset + response.issues.count) to see more.")
        }
        return lines.joined(separator: "\n")
    }

    static func formatIssueSummary(_ issue: Issue) -> String {
        var parts: [String] = []
        parts.append("#\(issue.id)")
        if let status = issue.status?.name { parts.append("[\(status)]") }
        if let priority = issue.priority?.name { parts.append("(\(priority))") }
        if let subject = issue.subject { parts.append(subject.sanitized) }

        var meta: [String] = []
        if let tracker = issue.tracker?.name { meta.append("Tracker: \(tracker)") }
        if let assignee = issue.assignedTo?.name { meta.append("Assigned: \(assignee)") }
        if let version = issue.fixedVersion?.name { meta.append("Sprint: \(version)") }
        if let due = issue.dueDate {
            if issue.closedOn == nil, let warning = Self.dueDateWarning(due) {
                meta.append(warning)
            } else {
                meta.append("Due: \(due)")
            }
        }

        var result = parts.joined(separator: " ")
        if !meta.isEmpty {
            result += "\n  " + meta.joined(separator: " | ")
        }
        return result
    }

    static func formatIssueDetail(_ issue: Issue, features: Features = .default, filter: IssueFilterOptions = .default) -> String {
        var lines: [String] = []
        lines.append("# Issue #\(issue.id): \(issue.subject ?? "No subject")")
        lines.append("")

        // Core fields — always rendered
        if let project = issue.project?.name { lines.append("Project: \(project)") }
        if let tracker = issue.tracker?.name { lines.append("Tracker: \(tracker)") }
        if let status = issue.status?.name { lines.append("Status: \(status)") }
        if let priority = issue.priority?.name { lines.append("Priority: \(priority)") }
        if let author = issue.author?.name { lines.append("Author: \(author)") }
        if let assignee = issue.assignedTo?.name { lines.append("Assigned to: \(assignee)") }
        if let version = issue.fixedVersion?.name { lines.append("Target version: \(version)") }
        if let category = issue.category?.name { lines.append("Category: \(category)") }
        if let parent = issue.parent { lines.append("Parent: #\(parent.id)") }
        if issue.isPrivate == true { lines.append("Private: yes (issue visible only to members allowed to see private issues)") }

        // Due date warning (non-closed issues only)
        if let dueDateStr = issue.dueDate, issue.closedOn == nil {
            if let warning = Self.dueDateWarning(dueDateStr) {
                lines.append(warning)
            }
        }

        // Dates
        if filter.shouldInclude("dates") {
            if let start = issue.startDate { lines.append("Start date: \(start)") }
            if let due = issue.dueDate { lines.append("Due date: \(due)") }
            if let done = issue.doneRatio { lines.append("Done: \(done)%") }
            if let created = issue.createdOn { lines.append("Created: \(created)") }
            if let updated = issue.updatedOn { lines.append("Updated: \(updated)") }
            if let closed = issue.closedOn { lines.append("Closed: \(closed)") }
        }

        // Hours
        if filter.shouldInclude("hours") {
            if let est = issue.estimatedHours { lines.append("Estimated: \(formatHours(est))") }
            if let totalEst = issue.totalEstimatedHours, totalEst != issue.estimatedHours {
                lines.append("Estimated (incl. sub-issues): \(formatHours(totalEst))")
            }
            if let spent = issue.spentHours { lines.append("Spent: \(formatHours(spent))") }
            if let totalSpent = issue.totalSpentHours, totalSpent != issue.spentHours {
                lines.append("Spent (incl. sub-issues): \(formatHours(totalSpent))")
            }
        }

        // Description
        if filter.shouldInclude("description") {
            if let desc = issue.description, !desc.isEmpty {
                lines.append("")
                lines.append("## Description")
                lines.append(desc)
            }
        }

        // Custom fields
        if filter.shouldInclude("custom_fields") {
            if let fields = issue.customFields, !fields.isEmpty {
                lines.append("")
                lines.append("## Custom Fields")
                for field in fields {
                    let val = field.value?.asString ?? "(empty)"
                    lines.append("- \(field.name ?? "Field \(field.id)"): \(val)")
                }
            }
        }

        // Checklists (parsed from journals)
        if filter.shouldInclude("journals") && features.checklists {
            let checklists = issue.parseChecklists()
            if !checklists.isEmpty {
                lines.append("")
                lines.append("## Checklist")
                lines.append("Use these IDs with checklists_attributes in update_issue.")
                for item in checklists {
                    let check = item.isDone ? "[x]" : "[ ]"
                    let idStr = item.id.map { "id:\($0)" } ?? "id:?"
                    lines.append("- \(check) \(item.subject) (\(idStr))")
                }
            }
        }

        // Children — the API nests sub-sub-issues recursively, render all levels
        if filter.shouldInclude("children") {
            if let children = issue.children, !children.isEmpty {
                func countAll(_ nodes: [Issue]) -> Int {
                    nodes.reduce(0) { $0 + 1 + countAll($1.children ?? []) }
                }
                lines.append("")
                lines.append("## Child Issues (\(countAll(children)) total)")
                appendChildLines(children, depth: 0, into: &lines)
                lines.append("")
                lines.append("Child entries only carry id/subject here. Use get_issue_tree for the full hierarchy with status, assignee, and time rollups.")
            }
        }

        // Relations — stored one-directional; invert the type when this issue
        // is on the receiving end so it never prints itself as the target.
        if filter.shouldInclude("relations") {
            if let relations = issue.relations, !relations.isEmpty {
                lines.append("")
                lines.append("## Relations")
                for rel in relations {
                    let type = rel.relationType ?? "relates"
                    if rel.issueToId == issue.id {
                        lines.append("- \(invertedRelation(type)) #\(rel.issueId)")
                    } else {
                        lines.append("- \(type) #\(rel.issueToId)")
                    }
                }
            }
        }

        // Attachments
        if filter.shouldInclude("attachments") {
            if let attachments = issue.attachments, !attachments.isEmpty {
                lines.append("")
                lines.append("## Attachments")
                for att in attachments {
                    var line = "- #\(att.id) \(att.filename ?? "file") (\(att.contentType ?? "unknown type"), \(formatBytes(Int64(att.filesize ?? 0))))"
                    var meta: [String] = []
                    if let author = att.author?.name { meta.append(author) }
                    if let created = att.createdOn { meta.append(created) }
                    if !meta.isEmpty { line += " — " + meta.joined(separator: ", ") }
                    if let desc = att.description, !desc.isEmpty { line += " — \"\(desc.sanitized)\"" }
                    lines.append(line)
                }
                lines.append("Use download_attachments to save files locally (e.g. to view screenshots); update_attachment / delete_attachment take these IDs.")
            }
        }

        // Watchers
        if filter.shouldInclude("watchers") {
            if let watchers = issue.watchers, !watchers.isEmpty {
                lines.append("")
                lines.append("## Watchers")
                for w in watchers {
                    lines.append("- \(w.name ?? "User \(w.id)")")
                }
            }
        }

        // Journals
        if filter.shouldInclude("journals") {
            if let journals = issue.journals, !journals.isEmpty {
                // Apply journals_since filter
                var filtered = journals
                if let since = filter.journalsSince {
                    filtered = filtered.filter { journal in
                        guard let date = journal.createdOn else { return false }
                        // Compare date strings (works for both YYYY-MM-DD and ISO 8601)
                        return date >= since
                    }
                }

                // Apply journals_limit (take last N)
                let total = filtered.count
                let limited = Array(filtered.suffix(filter.journalsLimit))

                // Build header reflecting filtering
                var header = "## Journal (last \(limited.count) of \(total) entries"
                if let since = filter.journalsSince {
                    header += ", since \(since)"
                }
                header += ")"

                lines.append("")
                lines.append(header)
                for journal in limited {
                    let user = journal.user?.name ?? "Unknown"
                    let date = journal.createdOn ?? ""
                    lines.append("")
                    let privacy = journal.privateNotes == true ? ", private" : ""
                    lines.append("### \(user) — \(date) (#\(journal.id)\(privacy))")
                    if let notes = journal.notes, !notes.isEmpty {
                        lines.append(notes)
                    }
                    if let details = journal.details {
                        for detail in details {
                            if detail.name == "checklist" { continue } // Already shown above
                            // Attachment details carry the attachment id as `name`
                            if detail.property == "attachment" {
                                let id = detail.name ?? "?"
                                if let added = detail.newValue?.asString {
                                    lines.append("  Attached #\(id): \(added)")
                                } else {
                                    lines.append("  Removed attachment #\(id): \(detail.oldValue?.asString ?? "?")")
                                }
                                continue
                            }
                            let old = detail.oldValue?.asString ?? "(none)"
                            let new = detail.newValue?.asString ?? "(none)"
                            lines.append("  Changed \(detail.name ?? "field"): \(old) → \(new)")
                        }
                    }
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }

    // MARK: - Issue Tree

    static func formatIssueTree(root: Issue, descendants: [Issue]) -> String {
        // Index the fetched descendants; the nested children structure from the
        // root detail defines the tree shape (list results carry the data).
        let byId = Dictionary(descendants.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var openCount = 0
        var closedCount = 0
        var estimatedSum = 0.0
        var withoutEstimate: [Int] = []
        var notVisible: [Int] = []
        var maxDepth = 0

        // Subtree estimate rollup, computed from the nested shape so it works
        // even when the server omits total_estimated_hours in list responses.
        func subtreeEstimate(_ node: Issue) -> Double {
            let resolved = byId[node.id] ?? node
            var sum = resolved.estimatedHours ?? 0
            for child in node.children ?? [] { sum += subtreeEstimate(child) }
            return sum
        }

        func countIssues(_ node: Issue) -> Int {
            (node.children ?? []).reduce(1) { $0 + countIssues($1) }
        }

        var lines: [String] = []

        func render(_ node: Issue, depth: Int) {
            maxDepth = max(maxDepth, depth)
            let indent = String(repeating: "  ", count: depth)

            // Nested children entries only carry id/tracker/subject — swap in
            // the fully-populated issue from the bulk list fetch.
            guard let issue = depth == 0 ? node : byId[node.id] else {
                notVisible.append(node.id)
                lines.append("\(indent)#\(node.id) [not visible] \(node.subject?.sanitized ?? "")")
                for child in node.children ?? [] { render(child, depth: depth + 1) }
                return
            }

            if depth > 0 {
                if issue.closedOn != nil || issue.status?.name?.lowercased().contains("closed") == true {
                    closedCount += 1
                } else {
                    openCount += 1
                }
                if let est = issue.estimatedHours {
                    estimatedSum += est
                } else {
                    withoutEstimate.append(issue.id)
                }
            }

            var parts: [String] = ["\(indent)#\(issue.id)"]
            if let status = issue.status?.name { parts.append("[\(status)]") }
            if let subject = issue.subject { parts.append(subject.sanitized) }

            var meta: [String] = []
            if let est = issue.estimatedHours { meta.append("est \(formatHours(est))") }
            if let spent = issue.spentHours, spent > 0 { meta.append("spent \(formatHours(spent))") }
            if let done = issue.doneRatio, done > 0 { meta.append("\(done)%") }
            if let assignee = issue.assignedTo?.name { meta.append("@\(assignee)") }
            if let due = issue.dueDate, issue.closedOn == nil { meta.append("due \(due)") }

            // Branch rollup on inner nodes so big epics are scannable per branch.
            // Prefer the server-side totals; fall back to summing visible nodes.
            if let children = node.children, !children.isEmpty, depth > 0 {
                let branchEst = issue.totalEstimatedHours ?? subtreeEstimate(node)
                let branchCount = countIssues(node) - 1
                var rollup = "subtree: \(branchCount) issues, est \(formatHours(branchEst))"
                if let branchSpent = issue.totalSpentHours, branchSpent > 0 {
                    rollup += ", spent \(formatHours(branchSpent))"
                }
                meta.append(rollup)
            }

            var line = parts.joined(separator: " ")
            if !meta.isEmpty { line += " — " + meta.joined(separator: ", ") }
            lines.append(line)

            for child in node.children ?? [] { render(child, depth: depth + 1) }
        }

        render(root, depth: 0)

        var header: [String] = []
        header.append("# Issue Tree: #\(root.id) \(root.subject?.sanitized ?? "")")
        if let project = root.project?.name { header.append("Project: \(project)") }

        let total = openCount + closedCount
        if total == 0 {
            header.append("No sub-issues.")
        } else {
            header.append("Sub-issues: \(total) (\(openCount) open, \(closedCount) closed), max depth \(maxDepth)")
        }

        // Prefer the server-side rollup (includes issues the tree fetch might
        // not see); fall back to our own sum from the visible nodes.
        let rootEst = root.estimatedHours ?? 0
        if let totalEst = root.totalEstimatedHours {
            header.append("Estimated total: \(formatHours(totalEst)) (root itself: \(formatHours(rootEst)))")
        } else if total > 0 {
            header.append("Estimated total: \(formatHours(estimatedSum + rootEst)) (root itself: \(formatHours(rootEst)))")
        }
        if let totalSpent = root.totalSpentHours {
            header.append("Spent total: \(formatHours(totalSpent)) (root itself: \(formatHours(root.spentHours ?? 0)))")
        }
        if let relations = root.relations, !relations.isEmpty {
            let rels = relations.map { rel -> String in
                let type = rel.relationType ?? "relates"
                if rel.issueToId == root.id {
                    return "\(invertedRelation(type)) #\(rel.issueId)"
                }
                return "\(type) #\(rel.issueToId)"
            }
            header.append("Relations: " + rels.joined(separator: ", "))
        }
        if !withoutEstimate.isEmpty {
            let ids = withoutEstimate.prefix(20).map { "#\($0)" }.joined(separator: ", ")
            let suffix = withoutEstimate.count > 20 ? ", …" : ""
            header.append("⚠ \(withoutEstimate.count) sub-issue\(withoutEstimate.count == 1 ? "" : "s") without estimate: \(ids)\(suffix)")
        }
        if !notVisible.isEmpty {
            header.append("⚠ \(notVisible.count) sub-issue\(notVisible.count == 1 ? "" : "s") not visible to you — totals may be incomplete")
        }

        if total == 0 {
            return header.joined(separator: "\n")
        }
        return header.joined(separator: "\n") + "\n\n" + lines.joined(separator: "\n")
    }

    private static func appendChildLines(_ children: [Issue], depth: Int, into lines: inout [String]) {
        let indent = String(repeating: "  ", count: depth)
        for child in children {
            var parts = ["\(indent)- #\(child.id)"]
            if let tracker = child.tracker?.name { parts.append("[\(tracker)]") }
            if let subject = child.subject { parts.append(subject.sanitized) }
            lines.append(parts.joined(separator: " "))
            if let nested = child.children, !nested.isEmpty {
                appendChildLines(nested, depth: depth + 1, into: &lines)
            }
        }
    }

    // Relations are stored one-directional; shown from the other side the
    // type must be inverted (e.g. #A blocks #B → #B is "blocked by #A").
    private static func invertedRelation(_ type: String) -> String {
        switch type {
        case "blocks": return "blocked by"
        case "precedes": return "follows"
        case "duplicates": return "duplicated by"
        case "copied_to": return "copied from"
        default: return type
        }
    }

    static func formatHours(_ hours: Double) -> String {
        if hours == hours.rounded() {
            return "\(Int(hours))h"
        }
        var s = String(format: "%.2f", hours)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s + "h"
    }

    // MARK: - Due Date Warning

    static func dueDateWarning(_ dueDateStr: String) -> String? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        guard let dueDate = formatter.date(from: dueDateStr) else { return nil }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let due = calendar.startOfDay(for: dueDate)
        let days = calendar.dateComponents([.day], from: today, to: due).day ?? 0

        if days < 0 {
            return "⚠ OVERDUE by \(-days) day\(-days == 1 ? "" : "s") (due \(dueDateStr))"
        } else if days == 0 {
            return "⚠ Due today (\(dueDateStr))"
        } else if days <= 3 {
            return "⚠ Due in \(days) day\(days == 1 ? "" : "s") (\(dueDateStr))"
        }
        return nil
    }

    // MARK: - Time Entries

    static func formatTimeEntryList(_ response: TimeEntriesResponse) -> String {
        var lines: [String] = []
        lines.append("Time Entries (\(response.totalCount) total, showing \(response.offset + 1)-\(response.offset + response.timeEntries.count)):")
        lines.append("")

        for entry in response.timeEntries {
            lines.append(formatTimeEntrySummary(entry))
        }

        if response.totalCount > response.offset + response.timeEntries.count {
            lines.append("")
            lines.append("Use offset=\(response.offset + response.timeEntries.count) to see more.")
        }
        return lines.joined(separator: "\n")
    }

    static func formatTimeEntryList(_ entries: [TimeEntry]) -> String {
        var lines: [String] = []
        lines.append("Time Entries (\(entries.count) total):")
        lines.append("")

        for entry in entries {
            lines.append(formatTimeEntrySummary(entry))
        }
        return lines.joined(separator: "\n")
    }

    static func formatTimeEntrySummary(_ entry: TimeEntry) -> String {
        var parts: [String] = []
        parts.append("ID:\(entry.id)")
        if let date = entry.spentOn { parts.append(date) }
        if let hours = entry.hours { parts.append("\(hours)h") }
        if let issue = entry.issue { parts.append("Issue #\(issue.id)") }
        if let project = entry.project?.name { parts.append(project) }
        if let activity = entry.activity?.name { parts.append("(\(activity))") }
        if let comment = entry.comments, !comment.isEmpty { parts.append("— \(comment.sanitized)") }
        return parts.joined(separator: " | ")
    }

    static func formatTimeEntryDetail(_ entry: TimeEntry) -> String {
        var lines: [String] = []
        lines.append("# Time Entry #\(entry.id)")
        if let project = entry.project?.name { lines.append("Project: \(project)") }
        if let issue = entry.issue { lines.append("Issue: #\(issue.id)") }
        if let user = entry.user?.name { lines.append("User: \(user)") }
        if let activity = entry.activity?.name { lines.append("Activity: \(activity)") }
        if let hours = entry.hours { lines.append("Hours: \(hours)") }
        if let date = entry.spentOn { lines.append("Date: \(date)") }
        if let comment = entry.comments, !comment.isEmpty { lines.append("Comment: \(comment.sanitized)") }
        if let created = entry.createdOn { lines.append("Created: \(created)") }
        if let updated = entry.updatedOn { lines.append("Updated: \(updated)") }
        return lines.joined(separator: "\n")
    }

    // MARK: - Projects

    static func formatProjectList(_ response: ProjectsResponse) -> String {
        var lines: [String] = []
        lines.append("Projects (\(response.totalCount) total, showing \(response.offset + 1)-\(response.offset + response.projects.count)):")
        lines.append("")
        for project in response.projects {
            var parts: [String] = []
            parts.append("ID:\(project.id)")
            if let name = project.name { parts.append(name) }
            if let ident = project.identifier { parts.append("(\(ident))") }
            lines.append(parts.joined(separator: " "))
        }
        if response.totalCount > response.offset + response.projects.count {
            lines.append("")
            lines.append("Use offset=\(response.offset + response.projects.count) to see more.")
        }
        return lines.joined(separator: "\n")
    }

    static func formatProjectDetail(_ project: Project) -> String {
        var lines: [String] = []
        lines.append("# Project: \(project.name ?? "Unknown")")
        lines.append("ID: \(project.id)")
        if let ident = project.identifier { lines.append("Identifier: \(ident)") }
        if let desc = project.description, !desc.isEmpty { lines.append("Description: \(desc)") }
        if let status = project.status { lines.append("Status: \(status == 1 ? "active" : "closed")") }
        if let created = project.createdOn { lines.append("Created: \(created)") }
        if let updated = project.updatedOn { lines.append("Updated: \(updated)") }

        if let trackers = project.trackers, !trackers.isEmpty {
            lines.append("")
            lines.append("## Trackers")
            for t in trackers { lines.append("- \(t.name ?? "Unknown") (ID: \(t.id))") }
        }
        if let categories = project.issueCategories, !categories.isEmpty {
            lines.append("")
            lines.append("## Issue Categories")
            for c in categories { lines.append("- \(c.name ?? "Unknown") (ID: \(c.id))") }
        }
        if let activities = project.timeEntryActivities, !activities.isEmpty {
            lines.append("")
            lines.append("## Time Entry Activities")
            for a in activities { lines.append("- \(a.name ?? "Unknown") (ID: \(a.id))") }
        }
        if let modules = project.enabledModules, !modules.isEmpty {
            lines.append("")
            lines.append("## Enabled Modules")
            for m in modules { lines.append("- \(m.name ?? "Unknown")") }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Users

    static func formatUserList(_ response: UsersResponse) -> String {
        var lines: [String] = []
        lines.append("Users (\(response.totalCount) total, showing \(response.offset + 1)-\(response.offset + response.users.count)):")
        lines.append("")
        for user in response.users {
            lines.append(formatUserSummary(user))
        }
        return lines.joined(separator: "\n")
    }

    static func formatUserSummary(_ user: User) -> String {
        var parts: [String] = []
        parts.append("ID:\(user.id)")
        if let name = user.name ?? user.firstname.map({ "\($0) \(user.lastname ?? "")" }) {
            parts.append(name)
        }
        if let login = user.login { parts.append("(\(login))") }
        if let mail = user.mail { parts.append(mail) }
        return parts.joined(separator: " ")
    }

    static func formatUserDetail(_ user: User) -> String {
        var lines: [String] = []
        lines.append("# User: \(user.name ?? "\(user.firstname ?? "") \(user.lastname ?? "")")")
        lines.append("ID: \(user.id)")
        if let login = user.login { lines.append("Login: \(login)") }
        if let mail = user.mail { lines.append("Email: \(mail)") }
        if let created = user.createdOn { lines.append("Created: \(created)") }
        if let lastLogin = user.lastLoginOn { lines.append("Last login: \(lastLogin)") }
        return lines.joined(separator: "\n")
    }
}
