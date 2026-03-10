import Foundation

actor PlanioClient {
    let baseURL: String
    let apiKey: String
    private let session: URLSession
    private let decoder: JSONDecoder

    // Runtime issue cache: [issueId: (data, fetchedAt)]
    private var issueCache: [Int: (data: Data, fetchedAt: Date)] = [:]
    private let cacheTTL: TimeInterval = 300 // 5 minutes

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

    func delete(path: String) async throws -> Int {
        let (status, data) = try await request(method: "DELETE", path: path)
        guard (200...299).contains(status) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ToolError.apiError(status, errorBody)
        }
        return status
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

    // Fetch issue with caching support
    func getIssue(id: Int, include: String? = nil) async throws -> Data {
        // Only use cache if no special include params (or journals included)
        let cacheKey = id
        if let cached = getCachedIssue(id: cacheKey), include == nil {
            return cached
        }

        var params: [String: String] = [:]
        if let include { params["include"] = include }

        let (status, data) = try await request(path: "/issues/\(id).json", queryParams: params.isEmpty ? nil : params)
        guard (200...299).contains(status) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ToolError.apiError(status, errorBody)
        }

        cacheIssue(id: cacheKey, data: data)
        return data
    }
}
