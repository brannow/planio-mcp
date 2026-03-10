import Foundation
import MCP

extension Value {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var intValue: Int? {
        if case .int(let i) = self { return i }
        if case .string(let s) = self { return Int(s) }
        if case .double(let d) = self { return Int(d) }
        return nil
    }

    var doubleValue: Double? {
        if case .double(let d) = self { return d }
        if case .int(let i) = self { return Double(i) }
        if case .string(let s) = self { return Double(s) }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var objectValue: [String: Value]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var arrayValue: [Value]? {
        if case .array(let a) = self { return a }
        return nil
    }
}

// Safe parameter extraction from tool arguments
struct ToolParams {
    let args: [String: Value]?

    func requireString(_ key: String) throws -> String {
        guard let val = args?[key]?.stringValue else {
            throw ToolError.missingParam(key)
        }
        return val
    }

    func requireInt(_ key: String) throws -> Int {
        guard let val = args?[key]?.intValue else {
            throw ToolError.missingParam(key)
        }
        return val
    }

    func optionalString(_ key: String) -> String? {
        args?[key]?.stringValue
    }

    func optionalInt(_ key: String) -> Int? {
        args?[key]?.intValue
    }

    func optionalDouble(_ key: String) -> Double? {
        args?[key]?.doubleValue
    }

    func optionalBool(_ key: String) -> Bool? {
        args?[key]?.boolValue
    }

    func optionalObject(_ key: String) -> [String: Value]? {
        args?[key]?.objectValue
    }

    func optionalArray(_ key: String) -> [Value]? {
        args?[key]?.arrayValue
    }
}

// MARK: - String Sanitization

extension String {
    /// Collapse newlines, carriage returns, tabs into single spaces for clean single-line output
    var sanitized: String {
        self.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

enum ToolError: LocalizedError {
    case missingParam(String)
    case apiError(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingParam(let name): return "Missing required parameter: \(name)"
        case .apiError(let code, let msg): return "API error (\(code)): \(msg)"
        }
    }
}
