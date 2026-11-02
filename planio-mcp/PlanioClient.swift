import Foundation

actor PlanioClient {
    let baseURL: String
    let apiKey: String
    private let session: URLSession
    private let decoder: JSONDecoder

    // Runtime issue cache: [issueId: (data, fetchedAt)]
    private var issueCache: [Int: (data: Data, fetchedAt: Date)] = [:]
    private let cacheTTL: TimeInterval = 300 // 5 minutes

    // Global metadata caches (not project-scoped)
    private var globalStatuses: (data: [IdName], fetchedAt: Date)?
    private var globalPriorities: (data: [IdName], fetchedAt: Date)?
    private var globalTrackers: (data: [IdName], fetchedAt: Date)?

    // Current user (immutable for process lifetime, fetched once)
    private var currentUser: User?

    // Per-project metadata cache
    struct ProjectMetadata {
        let trackers: [IdName]
        let categories: [IdName]
        let versions: [IdName]
        let activities: [IdName]
    }
    private var projectMetadata: [Int: (data: ProjectMetadata, fetchedAt: Date)] = [:]

    init(baseURL: String, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = URLSession.shared
        self.decoder = JSONDecoder()
    }

    // MARK: - Generic Request

    func request(
        method: String = "GET",
        path: String,
        queryParams: [String: String]? = nil,
        body: [String: Any]? = nil
    ) async throws -> (Int, Data) {
        var urlString = baseURL + path
        if !urlString.hasSuffix(".json") && !urlString.contains(".json?") {
            urlString += ".json"
        }

        var components = URLComponents(string: urlString)!
        if let params = queryParams {
            var items = components.queryItems ?? []
            for (key, value) in params {
                items.append(URLQueryItem(name: key, value: value))
            }
            components.queryItems = items
        }

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "X-Redmine-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as! HTTPURLResponse).statusCode
        return (statusCode, data)
    }

    // MARK: - Typed Request

    func get<T: Decodable>(path: String, queryParams: [String: String]? = nil) async throws -> T {
        let (status, data) = try await request(path: path, queryParams: queryParams)
        guard (200...299).contains(status) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ToolError.apiError(status, errorBody)
        }
        return try decoder.decode(T.self, from: data)
    }

    func post<T: Decodable>(path: String, body: [String: Any]) async throws -> T {
        let (status, data) = try await request(method: "POST", path: path, body: body)
        guard (200...299).contains(status) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ToolError.apiError(status, errorBody)
        }
        return try decoder.decode(T.self, from: data)
    }

    func put(path: String, body: [String: Any]) async throws -> (Int, Data) {
        let (status, data) = try await request(method: "PUT", path: path, body: body)
        guard (200...299).contains(status) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ToolError.apiError(status, errorBody)
        }
        return (status, data)
    }

    func patch(path: String, body: [String: Any]) async throws -> (Int, Data) {
        let (status, data) = try await request(method: "PATCH", path: path, body: body)
        guard (200...299).contains(status) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ToolError.apiError(status, errorBody)
        }
        return (status, data)
    }

    func delete(path: String) async throws -> Int {
        let (status, data) = try await request(method: "DELETE", path: path)
        guard (200...299).contains(status) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ToolError.apiError(status, errorBody)
        }
        return status
    }

    // MARK: - File Transfer
    // Kept apart from request(): that one forces a ".json" suffix and a JSON
    // Content-Type, which break the binary upload (406) and the download route.

    /// Step 1 of attaching a file: POST raw bytes to /uploads.json, streamed from disk.
    /// Returns the upload id (= the attachment id once attached) and the token
    /// that is passed in `uploads[]` of an issue create/update.
    func uploadFile(at fileURL: URL, filename: String) async throws -> (id: Int?, token: String) {
        var components = URLComponents(string: baseURL + "/uploads.json")!
        components.queryItems = [URLQueryItem(name: "filename", value: filename)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-Redmine-API-Key")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
        let status = (response as! HTTPURLResponse).statusCode
        guard (200...299).contains(status) else {
            // 422 carries Redmine's message, e.g. "exceeds the maximum allowed file size"
            throw ToolError.apiError(status, String(data: data, encoding: .utf8) ?? "Unknown error")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let upload = json["upload"] as? [String: Any],
              let token = upload["token"] as? String else {
            throw ToolError.apiError(status, "Unexpected upload response: \(String(data: data, encoding: .utf8) ?? "")")
        }
        return (upload["id"] as? Int, token)
    }

    /// Download an attachment's file to `destination` (overwritten if present).
    /// The URL is built from baseURL instead of trusting `content_url`, so the API key
    /// never leaves the configured host and filenames with spaces need no encoding.
    /// Redirects are NOT followed: without access Redmine answers 302 -> /login, and
    /// following it would silently save the HTML login page as the "file".
    func downloadAttachment(id: Int, to destination: URL) async throws -> (bytes: Int64, contentType: String?) {
        var request = URLRequest(url: URL(string: baseURL + "/attachments/download/\(id)")!)
        request.setValue(apiKey, forHTTPHeaderField: "X-Redmine-API-Key")

        let (tempURL, response) = try await session.download(for: request, delegate: NoRedirectDelegate())
        let http = response as! HTTPURLResponse
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard http.statusCode == 200 else {
            if (300...399).contains(http.statusCode) {
                throw ToolError.apiError(http.statusCode, "redirected to \(http.value(forHTTPHeaderField: "Location") ?? "?") — no access to this attachment (or invalid API key)")
            }
            let body = (try? String(contentsOf: tempURL, encoding: .utf8)) ?? ""
            throw ToolError.apiError(http.statusCode, String(body.prefix(300)))
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: tempURL, to: destination)
        let size = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? -1
        return (size, http.value(forHTTPHeaderField: "Content-Type"))
    }

    // MARK: - Issue Cache

    func getCachedIssue(id: Int) -> Data? {
        guard let entry = issueCache[id] else { return nil }
        if Date().timeIntervalSince(entry.fetchedAt) > cacheTTL {
            issueCache.removeValue(forKey: id)
            return nil
        }
        return entry.data
    }

    func cacheIssue(id: Int, data: Data) {
        issueCache[id] = (data: data, fetchedAt: Date())
    }

    func invalidateIssueCache(id: Int) {
        issueCache.removeValue(forKey: id)
    }

    /// Attachment PATCH/DELETE responses don't tell which issue the attachment
    /// belongs to, so after those we drop the whole cache rather than serve a
    /// stale attachment list from get_issue.
    func invalidateAllIssueCaches() {
        issueCache.removeAll()
    }

    // MARK: - Metadata (cached)

    func getStatuses() async throws -> [IdName] {
        if let cached = globalStatuses, Date().timeIntervalSince(cached.fetchedAt) <= cacheTTL {
            return cached.data
        }
        let response: StatusesResponse = try await get(path: "/issue_statuses")
        globalStatuses = (data: response.issueStatuses, fetchedAt: Date())
        return response.issueStatuses
    }

    func getPriorities() async throws -> [IdName] {
        if let cached = globalPriorities, Date().timeIntervalSince(cached.fetchedAt) <= cacheTTL {
            return cached.data
        }
        let response: PrioritiesResponse = try await get(path: "/enumerations/issue_priorities")
        globalPriorities = (data: response.issuePriorities, fetchedAt: Date())
        return response.issuePriorities
    }

    func getTrackers() async throws -> [IdName] {
        if let cached = globalTrackers, Date().timeIntervalSince(cached.fetchedAt) <= cacheTTL {
            return cached.data
        }
        let response: TrackersResponse = try await get(path: "/trackers")
        globalTrackers = (data: response.trackers, fetchedAt: Date())
        return response.trackers
    }

    func getProjectMetadata(projectId: Int) async throws -> ProjectMetadata {
        if let cached = projectMetadata[projectId], Date().timeIntervalSince(cached.fetchedAt) <= cacheTTL {
            return cached.data
        }
        let response: ProjectResponse = try await get(
            path: "/projects/\(projectId)",
            queryParams: ["include": "trackers,issue_categories,time_entry_activities,versions"]
        )
        let project = response.project
        let meta = ProjectMetadata(
            trackers: project.trackers ?? [],
            categories: project.issueCategories ?? [],
            versions: project.versions ?? [],
            activities: project.timeEntryActivities ?? []
        )
        projectMetadata[projectId] = (data: meta, fetchedAt: Date())
        return meta
    }

    func searchUsers(name: String) async throws -> [User] {
        let response: UsersResponse = try await get(
            path: "/users",
            queryParams: ["name": name, "limit": "10"]
        )
        return response.users
    }

    func getCurrentUser() async throws -> User {
        if let currentUser { return currentUser }
        let response: UserResponse = try await get(path: "/users/current")
        currentUser = response.user
        return response.user
    }

    // Fetch single issue — always full data (all includes), cache-aware
    func getIssue(id: Int) async throws -> Data {
        if let cached = getCachedIssue(id: id) {
            return cached
        }

        let allIncludes = "journals,children,attachments,relations,watchers,changesets"
        let (status, data) = try await request(
            path: "/issues/\(id).json",
            queryParams: ["include": allIncludes]
        )
        guard (200...299).contains(status) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ToolError.apiError(status, errorBody)
        }

        cacheIssue(id: id, data: data)
        return data
    }

    // Fetch many issues via the list endpoint (one request per 100 IDs).
    // Returns list-level data (status, assignee, estimated_hours, done_ratio, parent)
    // without journals/relations — much cheaper than per-issue detail fetches.
    func fetchIssuesByIds(_ ids: [Int]) async throws -> [Issue] {
        var all: [Issue] = []
        for chunk in ids.chunked(into: 100) {
            let csv = chunk.map(String.init).joined(separator: ",")
            let response: IssuesResponse = try await get(
                path: "/issues",
                queryParams: ["issue_id": csv, "status_id": "*", "limit": "100"]
            )
            all.append(contentsOf: response.issues)
        }
        return all
    }

    // Fetch multiple issues — cache-aware, parallel, full data
    // Skips IDs already in cache. Only uncached IDs hit the API.
    // onProgress fires after each issue completes (cached or fetched).
    func getIssues(
        ids: [Int],
        concurrency: Int = 10,
        onProgress: ((Int, Int) async -> Void)? = nil
    ) async throws -> [Int: Data] {
        var results: [Int: Data] = [:]
        var uncachedIds: [Int] = []

        // Partition: cached vs uncached
        for id in ids {
            if let cached = getCachedIssue(id: id) {
                results[id] = cached
            } else {
                uncachedIds.append(id)
            }
        }

        // Report cached hits as immediate progress
        let total = ids.count
        var completed = results.count
        if completed > 0 {
            await onProgress?(completed, total)
        }

        // Fetch uncached in parallel chunks
        for chunk in uncachedIds.chunked(into: concurrency) {
            try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                for id in chunk {
                    group.addTask {
                        let data = try await self.getIssue(id: id)
                        return (id, data)
                    }
                }
                for try await (id, data) in group {
                    results[id] = data
                    completed += 1
                    await onProgress?(completed, total)
                }
            }
        }
        return results
    }
}

/// Makes URLSession hand back 3xx responses instead of following them.
/// Completion-handler variant on purpose: the `async` overload crashes the
/// Swift 6.4.2 compiler (SILGen, emitNativeToForeignThunk) in this project.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
