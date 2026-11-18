struct IssueFilterOptions {
    let sections: Set<String>?   // nil = all sections (default), empty or ["metadata"] = core only
    let journalsLimit: Int       // default: 10
    let journalsSince: String?   // ISO date string
    var notesOnly: Bool = false  // skip journal entries without a comment

    static let `default` = IssueFilterOptions(sections: nil, journalsLimit: 10, journalsSince: nil)

    /// All possible heavy sections (everything beyond core metadata)
    static let allSections: Set<String> = [
        "description", "custom_fields", "journals", "children",
        "attachments", "relations", "watchers", "changesets", "hours", "dates"
    ]

    func shouldInclude(_ section: String) -> Bool {
        guard let sections else { return true }  // nil = show all
        return sections.contains(section)
    }
}
