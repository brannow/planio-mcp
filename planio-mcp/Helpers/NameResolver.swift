import Foundation

enum ResolvableField {
    case tracker, status, priority, category, version, activity, assignee
}

enum ResolveError: LocalizedError {
    case notFound(field: String, value: String, options: [String])
    case ambiguous(field: String, value: String, matches: [String])
    case requiresProject(field: String)
    case userDirectoryForbidden(value: String)

    var errorDescription: String? {
        switch self {
        case .notFound(let field, let value, let options):
            let list = options.joined(separator: ", ")
            return "No \(field) named '\(value)'. Available: \(list)"
        case .ambiguous(let field, let value, let matches):
            let list = matches.joined(separator: ", ")
            return "Ambiguous \(field) '\(value)'. Matches: \(list)"
        case .requiresProject(let field):
            return "\(field) resolution requires a project context (provide project_id)"
        case .userDirectoryForbidden(let value):
            return "Cannot resolve user '\(value)' without a project: Planio allows the user directory (/users) only for admins. Pass project_id (names are then matched against the project members) or a numeric user ID."
        }
    }
}

enum NameResolver {

    /// Resolve a name (or numeric string) to an ID.
    /// `project` is the project ID or identifier as a string — Redmine accepts both.
    static func resolve(
        _ value: String,
        field: ResolvableField,
        project: String?,
        client: PlanioClient
    ) async throws -> Int {
        // 1. Numeric pass-through (backward compat)
        if let id = Int(value) { return id }

        // 2. Assignee uses project memberships, not metadata
        if field == .assignee {
            return try await resolveUser(value, project: project, client: client)
        }

        // 3. Get candidates
        let candidates = try await candidates(for: field, project: project, client: client)
        let fieldName = Self.fieldName(field)

        // 4. Exact match (case-sensitive)
        let exactMatches = candidates.filter { $0.name == value }
        if exactMatches.count == 1 { return exactMatches[0].id }

        // 5. Case-insensitive match
        let lowered = value.lowercased()
        let ciMatches = candidates.filter { $0.name?.lowercased() == lowered }
        if ciMatches.count == 1 { return ciMatches[0].id }
        if ciMatches.count > 1 {
            throw ResolveError.ambiguous(
                field: fieldName,
                value: value,
                matches: ciMatches.compactMap { $0.name }
            )
        }

        // 6. No match — list available options
        let options = candidates.compactMap { $0.name }
        throw ResolveError.notFound(field: fieldName, value: value, options: options)
    }

    /// Resolve a user (or group) name to an ID.
    /// - "me" -> the current user.
    /// - With a project: match against its members (readable for every member).
    /// - Without: GET /users, which only admins may call; 403 becomes a clear error.
    static func resolveUser(_ value: String, project: String?, client: PlanioClient) async throws -> Int {
        if let id = Int(value) { return id }
        if value.lowercased() == "me" { return try await client.getCurrentUser().id }

        guard let project else {
            let users: [User]
            do {
                users = try await client.searchUsers(name: value)
            } catch ToolError.apiError(let code, _) where code == 403 {
                throw ResolveError.userDirectoryForbidden(value: value)
            }
            if users.count == 1 { return users[0].id }
            if users.count > 1 {
                let names = users.map { "\($0.name ?? $0.login ?? "ID:\($0.id)") (ID:\($0.id))" }
                throw ResolveError.ambiguous(field: "user", value: value, matches: names)
            }
            throw ResolveError.notFound(field: "user", value: value, options: ["no users found matching '\(value)'"])
        }

        let members = try await client.getProjectMembers(project: project)
        let label: (ProjectMember) -> String = { "\($0.name)\($0.isGroup ? " (group)" : "") (ID:\($0.id))" }

        // Exact name, ignoring case and diacritics ("Schone" == "Schöne")
        let exact = members.filter { fold($0.name) == fold(value) }
        if exact.count == 1 { return exact[0].id }
        if exact.count > 1 { throw ResolveError.ambiguous(field: "user", value: value, matches: exact.map(label)) }

        // Token prefix: every query word must start some word of the name.
        // "Thomas" / "thom sch" -> "Thomas Schöne"; "ann" does NOT match "Johann",
        // because a raw substring match is too loose for a write path.
        let queryTokens = tokens(value)
        let partial = members.filter { m in
            let nameTokens = tokens(m.name)
            return !queryTokens.isEmpty && queryTokens.allSatisfy { q in nameTokens.contains { $0.hasPrefix(q) } }
        }
        if partial.count == 1 { return partial[0].id }
        if partial.count > 1 { throw ResolveError.ambiguous(field: "user", value: value, matches: partial.map(label)) }

        let options = members.filter { !$0.isGroup }.map(label).sorted()
        throw ResolveError.notFound(field: "member of project \(project)", value: value, options: options)
    }

    /// Display name of a resolved principal, for echoing "Thomas -> Thomas Schöne (#52)".
    static func userLabel(_ id: Int, project: String?, client: PlanioClient) async -> String {
        if let project, let m = try? await client.getProjectMembers(project: project).first(where: { $0.id == id }) {
            return "\(m.name) (#\(id))"
        }
        if let me = try? await client.getCurrentUser(), me.id == id { return "\(me.name ?? "me") (#\(id))" }
        return "#\(id)"
    }

    // MARK: - Private

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func tokens(_ s: String) -> [String] {
        fold(s).split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "." }).map(String.init)
    }

    private static func candidates(
        for field: ResolvableField,
        project: String?,
        client: PlanioClient
    ) async throws -> [IdName] {
        switch field {
        case .tracker:
            if let project {
                return try await client.getProjectMetadata(project: project).trackers
            }
            return try await client.getTrackers()

        case .status:
            return try await client.getStatuses()

        case .priority:
            return try await client.getPriorities()

        case .category:
            guard let project else { throw ResolveError.requiresProject(field: "Category") }
            return try await client.getProjectMetadata(project: project).categories

        case .version:
            guard let project else { throw ResolveError.requiresProject(field: "Version") }
            // Only open versions: Redmine refuses to assign closed/locked ones anyway
            return try await client.getProjectMetadata(project: project).openVersions

        case .activity:
            guard let project else { throw ResolveError.requiresProject(field: "Activity") }
            return try await client.getProjectMetadata(project: project).activities

        case .assignee:
            return [] // handled by resolveUser
        }
    }

    private static func fieldName(_ field: ResolvableField) -> String {
        switch field {
        case .tracker: return "tracker"
        case .status: return "status"
        case .priority: return "priority"
        case .category: return "category"
        case .version: return "version"
        case .activity: return "activity"
        case .assignee: return "assignee"
        }
    }
}
