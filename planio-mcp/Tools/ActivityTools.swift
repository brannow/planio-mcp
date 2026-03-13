import Foundation
import MCP

enum ActivityTools {
    static func handle(_ params: CallTool.Parameters, client: PlanioClient, server: Server? = nil, features: Features = .default) async throws -> CallTool.Result {
        let progressToken = params._meta?.progressToken
        let p = ToolParams(args: params.arguments)
        let from = try p.requireString("from")
        let to = p.optionalString("to") ?? {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: Date())
        }()
        let userId = p.optionalInt("user_id")
        let projectIdRaw = p.optionalStringOrInt("project_id")

        // Progress helper — throttled to max once per 3 seconds, always fires on 100%
        var lastProgressMs: UInt64 = 0
        let progressIntervalMs: UInt64 = 3000

        let sendProgress: (Double, Double, String) async -> Void = { progress, total, message in
            guard let server, let token = progressToken else { return }
            let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
            guard (nowMs - lastProgressMs) >= progressIntervalMs else { return }
            lastProgressMs = nowMs

            let notification = ProgressNotification.message(
                .init(progressToken: token, progress: progress, total: total, message: message)
            )
            try? await server.notify(notification)
        }

        // Step 1: Resolve user ID if not provided
        await sendProgress(0, 100, "Resolving user...")
        let resolvedUserId: Int
        if let userId {
            resolvedUserId = userId
        } else {
            resolvedUserId = try await client.getCurrentUser().id
        }

        // Step 2: Fetch time entries for user in date range
        await sendProgress(5, 100, "Fetching time entries...")
        var timeQuery: [String: String] = [
            "user_id": String(resolvedUserId),
            "from": from,
            "to": to,
            "limit": "100"
        ]
        if let projectIdRaw { timeQuery["project_id"] = projectIdRaw }

        let (timeEntries, _, _) = try await fetchAllTimeEntries(client: client, query: timeQuery)

        // Step 3: Fetch issues authored by user in date range
        await sendProgress(15, 100, "Fetching authored issues...")
        var authorQuery: [String: String] = [
            "author_id": String(resolvedUserId),
            "created_on": "><\(from)|\(to)",
            "limit": "100"
        ]
        if let projectIdRaw { authorQuery["project_id"] = projectIdRaw }
        let authoredIssues: IssuesResponse = try await client.get(path: "/issues", queryParams: authorQuery)

        // Step 4: Full scan — all issues updated in date range
        await sendProgress(20, 100, "Scanning updated issues...")
        var scanQuery: [String: String] = [
            "updated_on": ">=\(from)",
            "status_id": "*",
            "limit": "100"
        ]
        if let projectIdRaw { scanQuery["project_id"] = projectIdRaw }
        let updatedIssues = try await fetchAllIssues(client: client, query: scanQuery)

        // Step 5: Collect unique issue IDs
        var issueIds = Set<Int>()
        for entry in timeEntries {
            if let issueId = entry.issue?.id { issueIds.insert(issueId) }
        }
        for issue in authoredIssues.issues {
            issueIds.insert(issue.id)
        }
        for issue in updatedIssues {
            issueIds.insert(issue.id)
        }

        await sendProgress(25, 100, "Loading \(issueIds.count) issues...")

        // Step 6: Fetch full issue details (cache-aware — only uncached IDs hit API)
        let issueDetails = try await client.getIssues(
            ids: Array(issueIds),
            concurrency: 10,
            onProgress: { completed, total in
                let progress = Double(Int(25.0 + (Double(completed) / Double(total)) * 65.0))
                await sendProgress(progress, 100, "Loading issues: \(completed) of \(total)...")
            }
        )

        await sendProgress(90, 100, "Building activity log...")

        // Step 7: Build per-issue, per-day activity log
        let decoder = JSONDecoder()

        // Structure: [date: [issueId: IssueLog]]
        var logByDate: [String: [Int: IssueLog]] = [:]

        // Add time entries (combine same issue + same day)
        for entry in timeEntries {
            let date = entry.spentOn ?? "unknown"
            guard let issueId = entry.issue?.id else { continue }
            let subject = issueDetails[issueId].flatMap { data in
                try? decoder.decode(IssueResponse.self, from: data).issue.subject
            }
            var log = logByDate[date, default: [:]][issueId] ?? IssueLog(issueId: issueId, subject: subject)
            log.totalHours += entry.hours ?? 0
            if let activity = entry.activity?.name, !log.activityNames.contains(activity) {
                log.activityNames.append(activity)
            }
            logByDate[date, default: [:]][issueId] = log
        }

        // Add journal entries by user
        for (issueId, data) in issueDetails {
            guard let issueResponse = try? decoder.decode(IssueResponse.self, from: data) else { continue }
            let issue = issueResponse.issue
            guard let journals = issue.journals else { continue }

            for journal in journals {
                guard journal.user?.id == resolvedUserId else { continue }
                guard let createdOn = journal.createdOn else { continue }
                let date = String(createdOn.prefix(10))
                guard date >= from && date <= to else { continue }

                var log = logByDate[date, default: [:]][issueId] ?? IssueLog(issueId: issueId, subject: issue.subject)

                // Collect actions
                if let notes = journal.notes, !notes.isEmpty {
                    let clean = notes.sanitized
                    let preview = String(clean.prefix(120))
                    log.actions.append("Comment: \(preview)\(clean.count > 120 ? "..." : "")")
                }
                if let details = journal.details {
                    for detail in details {
                        switch detail.name {
                        case "status_id":
                            log.actions.append("Status: \(detail.oldValue?.asString ?? "?") → \(detail.newValue?.asString ?? "?")")
                        case "assigned_to_id":
                            log.actions.append("Reassigned")
                        case "checklist" where features.checklists:
                            log.actions.append("Checklist updated")
                        case "done_ratio":
                            log.actions.append("Progress: \(detail.oldValue?.asString ?? "?")% → \(detail.newValue?.asString ?? "?")%")
                        case .some(let name) where name != "checklist":
                            log.actions.append("\(name) changed")
                        default:
                            break
                        }
                    }
                }

                logByDate[date, default: [:]][issueId] = log
            }

            // Created by user in date range
            if issue.author?.id == resolvedUserId, let createdOn = issue.createdOn {
                let date = String(createdOn.prefix(10))
                if date >= from && date <= to {
                    var log = logByDate[date, default: [:]][issueId] ?? IssueLog(issueId: issueId, subject: issue.subject)
                    log.actions.insert("Created", at: 0)
                    logByDate[date, default: [:]][issueId] = log
                }
            }
        }

        // Step 8: Format as plain log
        let output = formatLog(logByDate: logByDate, timeEntries: timeEntries, issueDetails: issueDetails, userId: resolvedUserId, from: from, to: to)

        return .init(content: [.text(output)])
    }

    // MARK: - Pagination Helpers

    static func fetchAllTimeEntries(client: PlanioClient, query: [String: String], maxEntries: Int? = nil) async throws -> (entries: [TimeEntry], totalCount: Int, capped: Bool) {
        var allEntries: [TimeEntry] = []
        var offset = 0
        var q = query
        var totalCount = 0

        while true {
            q["offset"] = String(offset)
            let response: TimeEntriesResponse = try await client.get(path: "/time_entries", queryParams: q)
            totalCount = response.totalCount
            allEntries.append(contentsOf: response.timeEntries)
            if let max = maxEntries, allEntries.count >= max {
                return (Array(allEntries.prefix(max)), totalCount, true)
            }
            if allEntries.count >= response.totalCount { break }
            offset += response.timeEntries.count
            if response.timeEntries.isEmpty { break }
        }
        return (allEntries, totalCount, false)
    }

    private static func fetchAllIssues(client: PlanioClient, query: [String: String]) async throws -> [Issue] {
        var allIssues: [Issue] = []
        var offset = 0
        var q = query

        while true {
            q["offset"] = String(offset)
            let response: IssuesResponse = try await client.get(path: "/issues", queryParams: q)
            allIssues.append(contentsOf: response.issues)
            if allIssues.count >= response.totalCount { break }
            offset += response.issues.count
            if response.issues.isEmpty { break }
        }
        return allIssues
    }

    // MARK: - Formatting

    private static func formatLog(
        logByDate: [String: [Int: IssueLog]],
        timeEntries: [TimeEntry],
        issueDetails: [Int: Data] = [:],
        userId: Int,
        from: String,
        to: String
    ) -> String {
        var lines: [String] = []
        lines.append("# Activity Log — User \(userId)")
        lines.append("Period: \(from) to \(to)")

        let totalHours = timeEntries.reduce(0.0) { $0 + ($1.hours ?? 0) }
        lines.append("Total booked: \(String(format: "%.1f", totalHours))h")
        lines.append("")

        // Pivot: date→issue into issue→date
        var byIssue: [Int: (subject: String?, dates: [String: IssueLog])] = [:]

        for (date, issues) in logByDate {
            for (issueId, log) in issues {
                if byIssue[issueId] == nil {
                    byIssue[issueId] = (subject: log.subject, dates: [:])
                }
                byIssue[issueId]?.dates[date] = log
            }
        }

        // Sort issues by earliest activity date
        let sortedIssues = byIssue.sorted { a, b in
            let aMin = a.value.dates.keys.min() ?? ""
            let bMin = b.value.dates.keys.min() ?? ""
            return aMin < bMin
        }

        let decoder = JSONDecoder()
        for (issueId, issueData) in sortedIssues {
            let subject = issueData.subject ?? "Unknown"
            var header = "#\(issueId): \(subject)"

            // Time budget from issue details
            if let data = issueDetails[issueId],
               let response = try? decoder.decode(IssueResponse.self, from: data) {
                let issue = response.issue
                if let spent = issue.spentHours, spent > 0 {
                    if let est = issue.estimatedHours, est > 0 {
                        header += " (\(String(format: "%.1f", spent))h of \(String(format: "%.1f", est))h)"
                    } else {
                        header += " (\(String(format: "%.1f", spent))h spent)"
                    }
                }
            }

            lines.append(header)

            let sortedDates = issueData.dates.keys.sorted()
            for date in sortedDates {
                guard let log = issueData.dates[date] else { continue }
                lines.append("  - \(date)")

                // Deduplicate actions
                var seen = Set<String>()
                for action in log.actions {
                    guard seen.insert(action).inserted else { continue }
                    lines.append("    - \(action)")
                }

                if log.totalHours > 0 {
                    var bookingLine = "    - Booked: \(String(format: "%.1f", log.totalHours))h"
                    if !log.activityNames.isEmpty {
                        bookingLine += " (\(log.activityNames.joined(separator: ", ")))"
                    }
                    lines.append(bookingLine)
                }
            }

            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Log Model

struct IssueLog {
    let issueId: Int
    let subject: String?
    var actions: [String] = []
    var totalHours: Double = 0
    var activityNames: [String] = []
}

// MARK: - Array Chunking

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
