import Foundation
import MCP
import UniformTypeIdentifiers

/// Issue attachments: download to disk, upload + attach, rename, delete.
/// Endpoints verified against Planio on 2026-11-02 (see kanban note #337).
enum AttachmentTools {
    static func handle(_ params: CallTool.Parameters, client: PlanioClient) async throws -> CallTool.Result {
        let p = ToolParams(args: params.arguments)

        switch params.name {
        case "download_attachments":
            return try await downloadAttachments(p, client: client)
        case "upload_attachments":
            return try await uploadAttachments(p, client: client)
        case "update_attachment":
            return try await updateAttachment(p, client: client)
        case "delete_attachment":
            return try await deleteAttachment(p, client: client)
        default:
            return .init(content: [.text("Unknown attachment tool: \(params.name)")], isError: true)
        }
    }

    // MARK: - Download

    /// Saves files to disk and returns paths instead of inlining content:
    /// no base64 in the agent's context, and the agent's own file Read tool
    /// already renders images. Works because the server runs locally over stdio.
    private static func downloadAttachments(_ p: ToolParams, client: PlanioClient) async throws -> CallTool.Result {
        let issueId = try p.requireInt("issue_id")
        let requestedIds = p.optionalArray("attachment_ids")?.compactMap { $0.intValue }

        var attachments = try await issueAttachments(issueId, client: client)
        // Cached issue data may predate a fresh upload — refetch once before giving up.
        if let ids = requestedIds, !Set(ids).isSubset(of: Set(attachments.map(\.id))) {
            await client.invalidateIssueCache(id: issueId)
            attachments = try await issueAttachments(issueId, client: client)
        }

        var selected = attachments
        var missing: [Int] = []
        if let ids = requestedIds, !ids.isEmpty {
            let byId = Dictionary(attachments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            selected = ids.compactMap { byId[$0] }
            missing = ids.filter { byId[$0] == nil }
        }
        guard !selected.isEmpty else {
            let msg = attachments.isEmpty
                ? "Issue #\(issueId) has no attachments."
                : "None of the requested attachment IDs belong to issue #\(issueId). Available: \(attachments.map { "#\($0.id) \($0.filename ?? "")" }.joined(separator: ", "))"
            return .init(content: [.text(msg)], isError: true)
        }

        let dir = try targetDirectory(p.optionalString("target_dir"), issueId: issueId)

        var lines: [String] = []
        var ok = 0
        for att in selected {
            // id prefix: several pasted "image.png" on one ticket are normal
            let dest = dir.appendingPathComponent("\(att.id)_\(safeFilename(att.filename ?? "attachment"))")
            do {
                let (bytes, servedType) = try await client.downloadAttachment(id: att.id, to: dest)
                // Second line of defense next to the no-redirect guard: an HTML page
                // (login, maintenance) served with 200 must not pass as the file.
                if let served = servedType?.lowercased(), served.hasPrefix("text/html"),
                   !(att.contentType ?? "").lowercased().hasPrefix("text/html") {
                    try? FileManager.default.removeItem(at: dest)
                    throw ToolError.invalid("server returned an HTML page instead of the file (login/maintenance?)")
                }
                var line = "- #\(att.id) \(dest.path) (\(att.contentType ?? "unknown type"), \(ResponseFormatter.formatBytes(bytes)))"
                if let expected = att.filesize, Int64(expected) != bytes {
                    line += " WARNING: expected \(expected) bytes"
                }
                lines.append(line)
                ok += 1
            } catch {
                lines.append("- #\(att.id) \(att.filename ?? "") FAILED: \(error.localizedDescription)")
            }
        }
        for id in missing {
            lines.append("- #\(id) FAILED: not an attachment of issue #\(issueId)")
        }

        let header = "Downloaded \(ok) of \(selected.count + missing.count) attachment(s) from #\(issueId) to \(dir.path):"
        let footer = "Open images/files with your own file Read tool using the paths above."
        return .init(
            content: [.text(([header] + lines + ["", footer]).joined(separator: "\n"))],
            isError: ok == 0
        )
    }

    private static func issueAttachments(_ issueId: Int, client: PlanioClient) async throws -> [Attachment] {
        let data = try await client.getIssue(id: issueId)
        return try JSONDecoder().decode(IssueResponse.self, from: data).issue.attachments ?? []
    }

    /// target_dir is optional because the server can't see the agent's scratchpad;
    /// default is $TMPDIR/planio-mcp/<issue_id>/.
    private static func targetDirectory(_ raw: String?, issueId: Int) throws -> URL {
        let dir: URL
        if let raw, !raw.isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else {
                throw ToolError.invalid("target_dir must be an absolute path, got '\(raw)'")
            }
            dir = URL(fileURLWithPath: expanded, isDirectory: true)
        } else {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("planio-mcp", isDirectory: true)
                .appendingPathComponent(String(issueId), isDirectory: true)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.standardizedFileURL
    }

    /// Server-provided names must not escape the target dir ("../", "/").
    private static func safeFilename(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        return cleaned.isEmpty ? "attachment" : cleaned
    }

    // MARK: - Upload

    private struct LocalFile {
        let url: URL
        let filename: String
        let description: String?
        let size: Int64
    }

    /// Two-step Redmine flow: upload each file -> token, then ONE issue PUT with all
    /// tokens (so all files land in a single journal entry, optionally with a note).
    /// If the PUT fails, the uploads are deleted again — an un-attached upload is a
    /// real attachment row with no container and would otherwise linger.
    private static func uploadAttachments(_ p: ToolParams, client: PlanioClient) async throws -> CallTool.Result {
        let issueId = try p.requireInt("issue_id")
        guard let rawFiles = p.optionalArray("files"), !rawFiles.isEmpty else {
            throw ToolError.missingParam("files")
        }
        let notes = p.optionalString("notes")
        let privateNotes = p.optionalBool("private_notes")
        if privateNotes == true && (notes ?? "").isEmpty {
            throw ToolError.invalid("private_notes requires notes — it marks the comment private, not the files. Attachments themselves have no visibility flag.")
        }

        // Validate everything before uploading anything.
        let fm = FileManager.default
        var files: [LocalFile] = []
        for raw in rawFiles {
            // Accept a bare path string as shorthand for {path}.
            let obj = raw.objectValue ?? (raw.stringValue.map { ["path": Value.string($0)] } ?? [:])
            guard let path = obj["path"]?.stringValue, !path.isEmpty else {
                throw ToolError.invalid("Each entry in files needs a 'path'.")
            }
            let expanded = (path as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else {
                throw ToolError.invalid("File path must be absolute: '\(path)'")
            }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: expanded, isDirectory: &isDir), !isDir.boolValue,
                  fm.isReadableFile(atPath: expanded) else {
                throw ToolError.invalid("File not found or not readable: \(expanded)")
            }
            let url = URL(fileURLWithPath: expanded)
            let size = (try? fm.attributesOfItem(atPath: expanded)[.size] as? Int64) ?? 0
            let filename = obj["filename"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? url.lastPathComponent
            files.append(LocalFile(url: url, filename: filename, description: obj["description"]?.stringValue, size: size))
        }

        // Step 1: upload each file.
        var uploaded: [(file: LocalFile, id: Int?, token: String)] = []
        do {
            for file in files {
                let (id, token) = try await client.uploadFile(at: file.url, filename: file.filename)
                uploaded.append((file, id, token))
            }
        } catch {
            let cleanup = await deleteOrphans(uploaded.compactMap(\.id), client: client)
            let failed = files[uploaded.count].filename
            throw ToolError.invalid("Upload of '\(failed)' failed: \(error.localizedDescription)\(cleanup)")
        }

        // Step 2: attach all tokens in one issue update.
        var issueData: [String: Any] = [
            "uploads": uploaded.map { u -> [String: Any] in
                var entry: [String: Any] = ["token": u.token, "filename": u.file.filename]
                if let desc = u.file.description, !desc.isEmpty { entry["description"] = desc }
                if let type = UTType(filenameExtension: u.file.url.pathExtension)?.preferredMIMEType {
                    entry["content_type"] = type
                }
                return entry
            }
        ]
        if let notes, !notes.isEmpty { issueData["notes"] = notes }
        if let privateNotes { issueData["private_notes"] = privateNotes }

        do {
            _ = try await client.put(path: "/issues/\(issueId)", body: ["issue": issueData])
        } catch {
            let cleanup = await deleteOrphans(uploaded.compactMap(\.id), client: client)
            throw ToolError.invalid("Files uploaded but attaching them to #\(issueId) failed: \(error.localizedDescription)\(cleanup)")
        }
        await client.invalidateIssueCache(id: issueId)

        var lines = ["Attached \(uploaded.count) file(s) to #\(issueId):"]
        for u in uploaded {
            let idStr = u.id.map { "#\($0)" } ?? "(id unknown)"
            lines.append("- \(idStr) \(u.file.filename) (\(ResponseFormatter.formatBytes(u.file.size)))")
        }
        if let notes, !notes.isEmpty {
            lines.append("With \(privateNotes == true ? "private" : "public") note.")
        }
        return .init(content: [.text(lines.joined(separator: "\n"))])
    }

    /// Best effort; returns a suffix for the error message describing the outcome.
    private static func deleteOrphans(_ ids: [Int], client: PlanioClient) async -> String {
        guard !ids.isEmpty else { return "" }
        var leftover: [Int] = []
        for id in ids {
            do { _ = try await client.delete(path: "/attachments/\(id)") } catch { leftover.append(id) }
        }
        return leftover.isEmpty
            ? " (already uploaded files were removed again)"
            : " (could not remove orphaned uploads: \(leftover.map { "#\($0)" }.joined(separator: ", ")))"
    }

    // MARK: - Update / Delete

    private static func updateAttachment(_ p: ToolParams, client: PlanioClient) async throws -> CallTool.Result {
        let attachmentId = try p.requireInt("attachment_id")
        var data: [String: Any] = [:]
        if let filename = p.optionalString("filename") {
            guard !filename.isEmpty else { throw ToolError.invalid("filename must not be empty") }
            data["filename"] = filename
        }
        if let description = p.optionalString("description") { data["description"] = description }
        guard !data.isEmpty else {
            return .init(content: [.text("Nothing to update. Provide filename and/or description.")], isError: true)
        }

        _ = try await client.patch(path: "/attachments/\(attachmentId)", body: ["attachment": data])
        await client.invalidateAllIssueCaches()
        return .init(content: [.text("Attachment #\(attachmentId) updated.")])
    }

    private static func deleteAttachment(_ p: ToolParams, client: PlanioClient) async throws -> CallTool.Result {
        let attachmentId = try p.requireInt("attachment_id")
        _ = try await client.delete(path: "/attachments/\(attachmentId)")
        await client.invalidateAllIssueCaches()
        return .init(content: [.text("Attachment #\(attachmentId) deleted.")])
    }
}
