import Foundation
import SQLite3

/// A top-level conversation of the Antigravity CLI (`agy`).
public struct AgySession: Sendable, Identifiable {
    public let id: String
    public let title: String?
    public let projectPath: String
    public let lastActivity: Date
    public let stepCount: Int

    public var projectName: String { (projectPath as NSString).lastPathComponent }
}

/// Reads `agy`'s conversation index (`~/.gemini/antigravity-cli/conversation_summaries.db`).
/// Opened with `immutable=1`: strictly read-only, no lock or journal files next to agy's database.
public enum AgySessionReader {
    public enum ReadError: LocalizedError {
        case sqlite(String)

        public var errorDescription: String? {
            switch self {
            case .sqlite(let message): "Could not read agy conversations: \(message)"
            }
        }
    }

    public static var defaultDatabase: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/conversation_summaries.db")
    }

    public static func read(database: URL = defaultDatabase, since cutoff: Date) throws -> [AgySession] {
        guard FileManager.default.fileExists(atPath: database.path) else { return [] }
        var db: OpaquePointer?
        let uri = "file:\(database.path)?mode=ro&immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            defer { sqlite3_close(db) }
            throw ReadError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_close(db) }

        // Subagent conversations (nesting_depth > 0) belong to their parent.
        let sql = """
            SELECT conversation_id, title, preview, workspace_uris, last_modified_time, step_count
            FROM conversation_summaries WHERE nesting_depth = 0
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ReadError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        let parser = ISO8601Parser()
        var sessions: [AgySession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ column: Int32) -> String {
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            }
            // Stored as "2026-10-14 10:17:40.490647+00:00".
            guard let modified = parser.parse(text(4).replacingOccurrences(of: " ", with: "T")),
                  modified >= cutoff,
                  let path = projectPath(fromWorkspaceURIs: text(3))
            else { continue }
            let title = text(1), preview = text(2)
            sessions.append(AgySession(
                id: text(0),
                title: !title.isEmpty ? title : (!preview.isEmpty ? String(preview.prefix(80)) : nil),
                projectPath: path,
                lastActivity: modified,
                stepCount: Int(sqlite3_column_int64(statement, 5))
            ))
        }
        return sessions.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// `["file:///Volumes/code/game"]` -> `/Volumes/code/game`.
    static func projectPath(fromWorkspaceURIs json: String) -> String? {
        guard let uris = try? JSONDecoder().decode([String].self, from: Data(json.utf8)),
              let first = uris.first, let url = URL(string: first), url.isFileURL
        else { return nil }
        return url.path
    }
}
