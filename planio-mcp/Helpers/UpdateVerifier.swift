import Foundation

/// Compares what update_issue sent with the issue as re-read after the PUT.
/// Redmine answers 204 even when it silently ignored attributes the user's
/// role/workflow may not change, so this is the only honest success message.
enum UpdateVerifier {

    /// - journalBaseline: highest journal id before the PUT; only newer journals
    ///   can contain the comment just posted.
    static func report(issueId: Int, requested: [String: Any], rawInput p: ToolParams, after: Issue, journalBaseline: Int) -> String {
        var ok: [String] = []
        var warnings: [String] = []

        func asked(_ key: String) -> String {
            p.optionalStringOrInt(key) ?? "\(requested[key] ?? "?")"
        }
        func check(_ key: String, label: String, actualId: Int?, actualName: String?) {
            guard let want = requested[key] else { return }
            let shown = actualName ?? actualId.map { "#\($0)" } ?? "(none)"
            // "" = clear the field
            if let s = want as? String, s.isEmpty {
                actualId == nil ? ok.append("\(label): cleared") : warnings.append("\(label) was NOT cleared, still \(shown)")
                return
            }
            if let id = want as? Int, id == actualId {
                ok.append("\(label): \(shown)")
            } else {
                warnings.append("\(label) was NOT changed: requested '\(asked(key))', issue still has \(shown)")
            }
        }
        func checkValue(_ key: String, label: String, actual: String?) {
            guard let want = requested[key] else { return }
            let wantStr = "\(want)"
            if (actual ?? "") == wantStr { ok.append("\(label): \(wantStr.isEmpty ? "cleared" : wantStr)") }
            else { warnings.append("\(label) was NOT changed: requested '\(wantStr)', issue has '\(actual ?? "(none)")'") }
        }

        check("status_id", label: "Status", actualId: after.status?.id, actualName: after.status?.name)
        check("tracker_id", label: "Tracker", actualId: after.tracker?.id, actualName: after.tracker?.name)
        check("priority_id", label: "Priority", actualId: after.priority?.id, actualName: after.priority?.name)
        check("assigned_to_id", label: "Assignee", actualId: after.assignedTo?.id, actualName: after.assignedTo?.name)
        check("fixed_version_id", label: "Version", actualId: after.fixedVersion?.id, actualName: after.fixedVersion?.name)
        check("category_id", label: "Category", actualId: after.category?.id, actualName: after.category?.name)
        check("parent_issue_id", label: "Parent", actualId: after.parent?.id, actualName: after.parent.map { "#\($0.id)" })

        checkValue("subject", label: "Subject", actual: after.subject)
        checkValue("start_date", label: "Start date", actual: after.startDate)
        checkValue("due_date", label: "Due date", actual: after.dueDate)

        if let want = requested["description"] as? String {
            norm(after.description) == norm(want)
                ? ok.append("Description updated")
                : warnings.append("Description was NOT changed as requested")
        }
        if let want = requested["estimated_hours"] as? Double {
            abs((after.estimatedHours ?? -1) - want) < 0.001
                ? ok.append("Estimate: \(ResponseFormatter.formatHours(want))")
                : warnings.append("Estimate was NOT changed: requested \(want)h, issue has \(after.estimatedHours.map { "\($0)h" } ?? "none")")
        }
        if let want = requested["done_ratio"] as? Int {
            want == after.doneRatio
                ? ok.append("Done: \(want)%")
                : warnings.append("Done % is \(after.doneRatio.map(String.init) ?? "?")% instead of \(want)% (Planio may derive it from the status or sub-issues)")
        }
        if let want = requested["is_private"] as? Bool {
            want == (after.isPrivate ?? false)
                ? ok.append("Private: \(want ? "yes" : "no")")
                : warnings.append("Issue privacy was NOT changed")
        }
        if let cfs = requested["custom_fields"] as? [[String: Any]] {
            for cf in cfs {
                guard let id = cf["id"] as? Int else { continue }
                let want = cf["value"] as? String ?? ""
                let field = after.customFields?.first { $0.id == id }
                let label = field?.name ?? "Custom field \(id)"
                guard let field else { warnings.append("\(label) is not on this issue (wrong ID, or not enabled for its tracker/project)"); continue }
                guard let actual = field.value?.asString else { ok.append("\(label): sent (multi-value, not compared)"); continue }
                actual == want ? ok.append("\(label): \(want.isEmpty ? "cleared" : want)") : warnings.append("\(label) was NOT changed: requested '\(want)', issue has '\(actual)'")
            }
        }
        if requested["checklists_attributes"] != nil {
            ok.append("Checklist changes sent (check with get_issue sections=journals)")
        }

        // The comment: find the newest journal carrying exactly this text
        if let notes = requested["notes"] as? String, !notes.isEmpty {
            let wantPrivate = requested["private_notes"] as? Bool ?? false
            if let j = after.journals?.last(where: { $0.id > journalBaseline && norm($0.notes) == norm(notes) }) {
                let isPrivate = j.privateNotes ?? false
                if isPrivate == wantPrivate {
                    ok.append("Comment posted (#\(j.id), \(isPrivate ? "private" : "public"))")
                } else {
                    warnings.append("Comment posted (#\(j.id)) but it is \(isPrivate ? "PRIVATE" : "PUBLIC"), requested \(wantPrivate ? "private" : "public") — your role may lack 'set notes private'")
                }
            } else {
                warnings.append("Comment NOT found in the journal after saving")
            }
        }

        var lines = ["Issue #\(issueId) re-read after saving:"]
        lines += ok.map { "- \($0)" }
        if !warnings.isEmpty {
            lines.append("")
            lines += warnings.map { "⚠ \($0)" }
            lines.append("Planio silently ignores fields your role or the workflow may not change (e.g. a status transition that isn't allowed) and still reports success.")
        }
        return lines.joined(separator: "\n")
    }

    private static func norm(_ s: String?) -> String {
        (s ?? "").replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
