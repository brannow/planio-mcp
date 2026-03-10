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
        if let due = issue.dueDate { meta.append("Due: \(due)") }

        var result = parts.joined(separator: " ")
        if !meta.isEmpty {
            result += "\n  " + meta.joined(separator: " | ")
        }
        return result
    }

    static func formatIssueDetail(_ issue: Issue, features: Features = .default) -> String {
        var lines: [String] = []
        lines.append("# Issue #\(issue.id): \(issue.subject ?? "No subject")")
        lines.append("")

        // Core fields
        if let project = issue.project?.name { lines.append("Project: \(project)") }
        if let tracker = issue.tracker?.name { lines.append("Tracker: \(tracker)") }
        if let status = issue.status?.name { lines.append("Status: \(status)") }
        if let priority = issue.priority?.name { lines.append("Priority: \(priority)") }
        if let author = issue.author?.name { lines.append("Author: \(author)") }
        if let assignee = issue.assignedTo?.name { lines.append("Assigned to: \(assignee)") }
        if let version = issue.fixedVersion?.name { lines.append("Target version: \(version)") }
        if let category = issue.category?.name { lines.append("Category: \(category)") }
        if let parent = issue.parent { lines.append("Parent: #\(parent.id)") }

        // Dates
        if let start = issue.startDate { lines.append("Start date: \(start)") }
        if let due = issue.dueDate { lines.append("Due date: \(due)") }
        if let done = issue.doneRatio { lines.append("Done: \(done)%") }

        // Hours
        if let est = issue.estimatedHours { lines.append("Estimated: \(est)h") }
        if let spent = issue.spentHours { lines.append("Spent: \(spent)h") }

        // Timestamps
        if let created = issue.createdOn { lines.append("Created: \(created)") }
        if let updated = issue.updatedOn { lines.append("Updated: \(updated)") }
        if let closed = issue.closedOn { lines.append("Closed: \(closed)") }

        // Description
        if let desc = issue.description, !desc.isEmpty {
            lines.append("")
            lines.append("## Description")
            lines.append(desc)
        }

        // Custom fields
        if let fields = issue.customFields, !fields.isEmpty {
            lines.append("")
            lines.append("## Custom Fields")
            for field in fields {
                let val = field.value?.asString ?? "(empty)"
                lines.append("- \(field.name ?? "Field \(field.id)"): \(val)")
            }
        }

        // Checklists (requires plugin)
        if features.checklists {
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

        // Children
        if let children = issue.children, !children.isEmpty {
            lines.append("")
            lines.append("## Child Issues")
            for child in children {
                lines.append("- \(formatIssueSummary(child))")
            }
        }

        // Relations
        if let relations = issue.relations, !relations.isEmpty {
            lines.append("")
            lines.append("## Relations")
            for rel in relations {
                lines.append("- \(rel.relationType ?? "related") #\(rel.issueToId)")
            }
        }

        // Attachments
        if let attachments = issue.attachments, !attachments.isEmpty {
            lines.append("")
            lines.append("## Attachments")
            for att in attachments {
                lines.append("- \(att.filename ?? "file") (\(att.filesize ?? 0) bytes)")
            }
        }

        // Watchers
        if let watchers = issue.watchers, !watchers.isEmpty {
            lines.append("")
            lines.append("## Watchers")
            for w in watchers {
                lines.append("- \(w.name ?? "User \(w.id)")")
            }
        }

        // Journals (recent, last 10)
        if let journals = issue.journals, !journals.isEmpty {
            lines.append("")
            lines.append("## Journal (last \(min(journals.count, 10)) of \(journals.count) entries)")
            for journal in journals.suffix(10) {
                let user = journal.user?.name ?? "Unknown"
                let date = journal.createdOn ?? ""
                lines.append("")
                lines.append("### \(user) — \(date)")
                if let notes = journal.notes, !notes.isEmpty {
                    lines.append(notes)
                }
                if let details = journal.details {
                    for detail in details {
                        if detail.name == "checklist" { continue } // Already shown above
                        let old = detail.oldValue?.asString ?? "(none)"
                        let new = detail.newValue?.asString ?? "(none)"
                        lines.append("  Changed \(detail.name ?? "field"): \(old) → \(new)")
                    }
                }
            }
        }

        return lines.joined(separator: "\n")
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
