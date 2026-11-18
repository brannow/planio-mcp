import Foundation

/// ID -> name maps for rendering journal details. Journals store raw IDs
/// ("status_id: 6 -> 54"), which an agent cannot read without extra calls.
/// Built once per tool call from the (cached) metadata endpoints; every map
/// is best-effort — a missing entry falls back to the raw ID.
struct NameLookup {
    var statuses: [Int: String] = [:]
    var priorities: [Int: String] = [:]
    var trackers: [Int: String] = [:]
    var principals: [Int: String] = [:]
    var versions: [Int: String] = [:]
    var categories: [Int: String] = [:]

    static let empty = NameLookup()

    /// Only fetches what the journals actually reference, so a plain get_issue
    /// without e.g. assignee changes costs no extra request.
    static func build(for issues: [Issue], client: PlanioClient) async -> NameLookup {
        var lookup = NameLookup()
        var needed = Set<String>()
        var projectsNeeding: [String: Set<String>] = [:]

        for issue in issues {
            // Names already present in the issue payload — free, and they cover
            // people who have since left the project.
            for ref in [issue.author, issue.assignedTo].compactMap({ $0 }) {
                if let name = ref.name { lookup.principals[ref.id] = name }
            }
            for w in issue.watchers ?? [] { if let name = w.name { lookup.principals[w.id] = name } }
            for j in issue.journals ?? [] {
                if let u = j.user, let name = u.name { lookup.principals[u.id] = name }
                for d in j.details ?? [] where d.property == "attr" {
                    guard let name = d.name else { continue }
                    needed.insert(name)
                    if let pid = issue.project?.id, ["assigned_to_id", "fixed_version_id", "category_id"].contains(name) {
                        projectsNeeding[String(pid), default: []].insert(name)
                    }
                }
            }
            if let v = issue.fixedVersion, let name = v.name { lookup.versions[v.id] = name }
            if let c = issue.category, let name = c.name { lookup.categories[c.id] = name }
        }

        func index(_ list: [IdName]) -> [Int: String] {
            Dictionary(list.compactMap { i in i.name.map { (i.id, $0) } }, uniquingKeysWith: { a, _ in a })
        }
        if needed.contains("status_id"), let s = try? await client.getStatuses() { lookup.statuses = index(s) }
        if needed.contains("priority_id"), let p = try? await client.getPriorities() { lookup.priorities = index(p) }
        if needed.contains("tracker_id"), let t = try? await client.getTrackers() { lookup.trackers = index(t) }

        for (project, fields) in projectsNeeding {
            if fields.contains("assigned_to_id"), let members = try? await client.getProjectMembers(project: project) {
                for m in members where lookup.principals[m.id] == nil { lookup.principals[m.id] = m.name }
            }
            if !fields.isDisjoint(with: ["fixed_version_id", "category_id"]),
               let meta = try? await client.getProjectMetadata(project: project) {
                lookup.versions.merge(index(meta.versions)) { a, _ in a }
                lookup.categories.merge(index(meta.categories)) { a, _ in a }
            }
        }
        return lookup
    }
}

enum JournalRenderer {

    /// Text fields longer than this (or multi-line) are shown as a line diff
    /// instead of old + new in full — a one-word edit of a long description
    /// otherwise prints the whole description twice.
    static let longTextThreshold = 150

    /// Render one journal detail.
    /// - diffLines: max changed lines to show for long text; nil = summary only
    ///   ("Description edited (+3/-2 lines)"), used by the compact change feed.
    /// - Returns: lines without leading indentation; first line is the summary.
    static func describe(_ d: JournalDetail, issue: Issue, lookup: NameLookup, diffLines: Int?) -> [String] {
        let oldRaw = d.oldValue?.asString
        let newRaw = d.newValue?.asString

        switch d.property {
        case "attachment":
            // Attachment details carry the attachment id as `name`
            let id = d.name ?? "?"
            if let added = newRaw { return ["Attached #\(id): \(added)"] }
            return ["Removed attachment #\(id): \(oldRaw ?? "?")"]

        case "relation":
            // Redmine journals relations on both issues, already from that
            // issue's perspective; `name` is the type, the value the other issue.
            let type = (d.name ?? "relates").replacingOccurrences(of: "_", with: " ")
            if let to = newRaw { return ["Relation added: \(type) #\(to)"] }
            return ["Relation removed: \(type) #\(oldRaw ?? "?")"]

        case "cf":
            let cfId = d.name.flatMap { Int($0) }
            let label = issue.customFields?.first(where: { $0.id == cfId })?.name ?? "Custom field \(d.name ?? "?")"
            return change(label: label, old: oldRaw, new: newRaw, diffLines: diffLines)

        default: // "attr"
            let name = d.name ?? "field"
            return change(
                label: label(for: name),
                old: oldRaw.map { value(for: name, raw: $0, lookup: lookup) },
                new: newRaw.map { value(for: name, raw: $0, lookup: lookup) },
                diffLines: diffLines
            )
        }
    }

    private static func change(label: String, old: String?, new: String?, diffLines: Int?) -> [String] {
        let old = old.flatMap { $0.isEmpty ? nil : $0 }
        let new = new.flatMap { $0.isEmpty ? nil : $0 }

        if isLong(old) || isLong(new) {
            let diff = lineDiff(old: old ?? "", new: new ?? "")
            if diff.whitespaceOnly {
                return ["\(label) changed (whitespace/line endings only)"]
            }
            var lines = ["\(label) edited (+\(diff.added)/-\(diff.removed) lines)"]
            guard let max = diffLines else { return lines }
            lines.append(contentsOf: diff.lines.prefix(max))
            if diff.lines.count > max { lines.append("… \(diff.lines.count - max) more changed lines") }
            return lines
        }

        switch (old, new) {
        case (nil, let n?): return ["\(label): set to \(n)"]
        case (let o?, nil): return ["\(label): cleared (was \(o))"]
        default: return ["\(label): \(old ?? "(none)") → \(new ?? "(none)")"]
        }
    }

    private static func isLong(_ s: String?) -> Bool {
        guard let s else { return false }
        return s.count > longTextThreshold || s.contains(where: \.isNewline)
    }

    private static func label(for field: String) -> String {
        switch field {
        case "status_id": return "Status"
        case "assigned_to_id": return "Assignee"
        case "fixed_version_id": return "Version"
        case "priority_id": return "Priority"
        case "tracker_id": return "Tracker"
        case "category_id": return "Category"
        case "parent_id": return "Parent"
        case "project_id": return "Project"
        case "done_ratio": return "Done %"
        case "estimated_hours": return "Estimate"
        case "start_date": return "Start date"
        case "due_date": return "Due date"
        case "is_private": return "Private"
        case "subject": return "Subject"
        case "description": return "Description"
        default: return field
        }
    }

    private static func value(for field: String, raw: String, lookup: NameLookup) -> String {
        guard let id = Int(raw) else { return raw }
        let name: String?
        switch field {
        case "status_id": name = lookup.statuses[id]
        case "priority_id": name = lookup.priorities[id]
        case "tracker_id": name = lookup.trackers[id]
        case "assigned_to_id": name = lookup.principals[id]
        case "fixed_version_id": name = lookup.versions[id]
        case "category_id": name = lookup.categories[id]
        case "parent_id": return "#\(id)"
        default: return raw
        }
        return name ?? raw
    }

    // MARK: - Line diff

    struct LineDiff {
        let added: Int
        let removed: Int
        let lines: [String]   // "- old line" / "+ new line", interleaved in document order
        let whitespaceOnly: Bool
    }

    /// Changed lines only (no context). Line endings are normalized first:
    /// Planio stores web-UI edits with \r\n and API edits with \n, and in Swift
    /// "\r\n" is a single Character, so it must be replaced, not split on.
    static func lineDiff(old: String, new: String, maxLineLength: Int = 200) -> LineDiff {
        func normalize(_ s: String) -> [String] {
            s.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
        }
        let a = normalize(old)
        let b = normalize(new)

        let trimmed: ([String]) -> [String] = { $0.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        if a != b && trimmed(a) == trimmed(b) {
            return LineDiff(added: 0, removed: 0, lines: [], whitespaceOnly: true)
        }

        let diff = b.difference(from: a)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        // Merge-walk both sides to interleave removals/insertions in document order
        func clip(_ s: String) -> String {
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.count > maxLineLength ? String(t.prefix(maxLineLength)) + "…" : t
        }
        var out: [String] = []
        var addedCount = 0, removedCount = 0
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) {
                let line = clip(a[i]); i += 1
                guard !line.isEmpty else { continue }   // blank-line churn is noise
                removedCount += 1; out.append("- \(line)")
            } else if j < b.count, inserted.contains(j) {
                let line = clip(b[j]); j += 1
                guard !line.isEmpty else { continue }
                addedCount += 1; out.append("+ \(line)")
            } else {
                i += 1; j += 1
            }
        }
        return LineDiff(added: addedCount, removed: removedCount, lines: out, whitespaceOnly: false)
    }
}
