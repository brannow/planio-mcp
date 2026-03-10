import Foundation

struct Features {
    let checklists: Bool

    static let `default` = Features(checklists: false)
}

struct Config {
    let baseURL: String
    let apiKey: String
    let features: Features

    static func load() throws -> Config {
        let env = ProcessInfo.processInfo.environment

        // Environment variables take precedence
        let url = env["TICKET_URL"] ?? envFileValue(for: "TICKET_URL")
        let key = env["TICKET_KEY"] ?? envFileValue(for: "TICKET_KEY")

        guard let url, !url.isEmpty else {
            throw ConfigError.missing("TICKET_URL not found in environment or .env file")
        }
        guard let key, !key.isEmpty else {
            throw ConfigError.missing("TICKET_KEY not found in environment or .env file")
        }

        // Feature flags (opt-in, default false)
        let checklists = envBool("FEATURE_CHECKLISTS", env: env)

        return Config(
            baseURL: url.trimmingCharacters(in: .init(charactersIn: "/")),
            apiKey: key,
            features: Features(checklists: checklists)
        )
    }

    private static func envBool(_ key: String, env: [String: String]) -> Bool {
        let raw = env[key] ?? envFileValue(for: key)
        guard let raw else { return false }
        return ["1", "true", "yes"].contains(raw.lowercased())
    }

    private static func envFileValue(for key: String) -> String? {
        // Resolve the directory containing the actual binary
        let executablePath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let executableDir = executablePath.deletingLastPathComponent()

        var candidates: [URL] = []

        // 1. Explicit --env /path/to/.env argument (highest priority)
        if let envArgIndex = CommandLine.arguments.firstIndex(of: "--env"),
           envArgIndex + 1 < CommandLine.arguments.count {
            candidates.append(URL(fileURLWithPath: CommandLine.arguments[envArgIndex + 1]))
        }

        // 2. Next to the binary (common MCP deployment)
        candidates.append(executableDir.appendingPathComponent(".env"))

        // 3. Current working directory
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env"))

        for candidate in candidates {
            guard let contents = try? String(contentsOf: candidate, encoding: .utf8) else { continue }
            for line in contents.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
                let k = String(trimmed[trimmed.startIndex..<eqIndex]).trimmingCharacters(in: .whitespaces)
                let v = String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
                if k == key { return v }
            }
        }
        return nil
    }
}

enum ConfigError: LocalizedError {
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .missing(let msg): return msg
        }
    }
}
