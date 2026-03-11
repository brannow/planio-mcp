import Foundation

enum ResolvableField {
    case tracker, status, priority, category, version, activity, assignee
}

enum ResolveError: LocalizedError {
    case notFound(field: String, value: String, options: [String])
    case ambiguous(field: String, value: String, matches: [String])
    case requiresProject(field: String)

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
        }
    }
}

enum NameResolver {

    static func resolve(
        _ value: String,
        field: ResolvableField,
        projectId: Int?,
        client: PlanioClient
    ) async throws -> Int {
        // 1. Numeric pass-through (backward compat)
        if let id = Int(value) { return id }

        // 2. Assignee uses user search, not metadata
        if field == .assignee {
            return try await resolveAssignee(value, client: client)
        }

        // 3. Get candidates
        let candidates = try await candidates(for: field, projectId: projectId, client: client)
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

    // MARK: - Private

    private static func candidates(
        for field: ResolvableField,
        projectId: Int?,
        client: PlanioClient
    ) async throws -> [IdName] {
        switch field {
        case .tracker:
            if let pid = projectId {
                return try await client.getProjectMetadata(projectId: pid).trackers
            }
            return try await client.getTrackers()

        case .status:
            return try await client.getStatuses()

        case .priority:
            return try await client.getPriorities()

        case .category:
            guard let pid = projectId else { throw ResolveError.requiresProject(field: "Category") }
            return try await client.getProjectMetadata(projectId: pid).categories

        case .version:
            guard let pid = projectId else { throw ResolveError.requiresProject(field: "Version") }
            return try await client.getProjectMetadata(projectId: pid).versions

        case .activity:
            guard let pid = projectId else { throw ResolveError.requiresProject(field: "Activity") }
            return try await client.getProjectMetadata(projectId: pid).activities

        case .assignee:
            return [] // handled separately
        }
    }

    private static func resolveAssignee(_ name: String, client: PlanioClient) async throws -> Int {
        let users = try await client.searchUsers(name: name)
        if users.count == 1 { return users[0].id }
        if users.count > 1 {
            let names = users.map { "\($0.name ?? $0.login ?? "ID:\($0.id)") (ID:\($0.id))" }
            throw ResolveError.ambiguous(field: "assignee", value: name, matches: names)
        }
        throw ResolveError.notFound(field: "assignee", value: name, options: ["No users found matching '\(name)'"])
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
