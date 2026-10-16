import Foundation

/// An OpenCode session. OpenCode keeps no plan/rate-limit data locally, so only sessions and the
/// cost OpenCode estimates from model prices are available.
public struct OpenCodeSession: Sendable, Identifiable {
    public let id: String
    public let title: String?
    public let projectPath: String
    public let lastActivity: Date
    public let cost: Double
    public let totalTokens: Int
    public let model: String?
}

/// Reads OpenCode's SQLite database (`$XDG_DATA_HOME/opencode/opencode.db`, default
/// `~/.local/share/opencode/opencode.db`). Supports the 2.x `session_v2` table and falls back to the
/// 1.x `session`/`message` tables (JSON in a `data` column).
public enum OpenCodeReader {
    public static var database: URL {
        let env = ProcessInfo.processInfo.environment
        if let path = env["OPENCODE_DB"] { return URL(fileURLWithPath: path) }
        let dataHome = env["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
        return dataHome.appendingPathComponent("opencode/opencode.db")
    }

    public static var isInstalled: Bool { FileManager.default.fileExists(atPath: database.path) }

    public static func sessions(database: URL = database, since cutoff: Date) throws -> [OpenCodeSession] {
        guard FileManager.default.fileExists(atPath: database.path) else { return [] }
        let db = try SQLiteReader(database)
        let cutoffMillis = String(Int64(cutoff.timeIntervalSince1970 * 1000))
        if db.tableExists("session_v2") {
            return try db.rows("""
                SELECT id, title, directory, model, cost, time_updated,
                       tokens_input + tokens_output + tokens_reasoning + tokens_cache_read + tokens_cache_write AS tokens
                FROM session_v2
                WHERE parent_id IS NULL AND time_archived IS NULL AND time_updated >= CAST(? AS INTEGER)
                ORDER BY time_updated DESC
                """, [cutoffMillis])
                .compactMap { row in
                    guard let id = row["id"] as? String, let directory = row["directory"] as? String,
                          let updated = row["time_updated"] as? Int64 else { return nil }
                    return OpenCodeSession(
                        id: id, title: (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                        projectPath: directory, lastActivity: Date(timeIntervalSince1970: Double(updated) / 1000),
                        cost: number(row["cost"]), totalTokens: Int(number(row["tokens"])),
                        model: (row["model"] as? String).flatMap(modelID(fromJSON:))
                    )
                }
        }
        if db.tableExists("session") {
            return try legacySessions(db, cutoff: cutoff)
        }
        return []
    }

    /// 1.x layout: `session.data` / `message.data` hold JSON documents.
    private static func legacySessions(_ db: SQLiteReader, cutoff: Date) throws -> [OpenCodeSession] {
        struct Session: Decodable {
            struct Time: Decodable { let updated: Double? }
            let id: String
            let title: String?
            let directory: String?
            let parentID: String?
            let time: Time?
        }
        struct Message: Decodable {
            struct Tokens: Decodable {
                struct Cache: Decodable { let read: Double?; let write: Double? }
                let input: Double?; let output: Double?; let reasoning: Double?; let cache: Cache?
            }
            let sessionID: String?
            let role: String?
            let cost: Double?
            let modelID: String?
            let tokens: Tokens?
        }
        let decoder = JSONDecoder()
        var costs: [String: (cost: Double, tokens: Double, model: String?)] = [:]
        for row in try db.rows("SELECT data FROM message") {
            guard let message = jsonData(row["data"]).flatMap({ try? decoder.decode(Message.self, from: $0) }),
                  message.role == "assistant", let sessionID = message.sessionID else { continue }
            let t = message.tokens
            let tokens = (t?.input ?? 0) + (t?.output ?? 0) + (t?.reasoning ?? 0) + (t?.cache?.read ?? 0) + (t?.cache?.write ?? 0)
            let previous = costs[sessionID] ?? (0, 0, nil)
            costs[sessionID] = (previous.cost + (message.cost ?? 0), previous.tokens + tokens, message.modelID ?? previous.model)
        }
        return try db.rows("SELECT data FROM session").compactMap { row -> OpenCodeSession? in
            guard let session = jsonData(row["data"]).flatMap({ try? decoder.decode(Session.self, from: $0) }),
                  session.parentID == nil, let directory = session.directory, let updated = session.time?.updated
            else { return nil }
            let lastActivity = Date(timeIntervalSince1970: updated / 1000)
            guard lastActivity >= cutoff else { return nil }
            let usage = costs[session.id]
            return OpenCodeSession(id: session.id, title: session.title, projectPath: directory, lastActivity: lastActivity,
                                   cost: usage?.cost ?? 0, totalTokens: Int(usage?.tokens ?? 0), model: usage?.model)
        }
        .sorted { $0.lastActivity > $1.lastActivity }
    }

    private static func number(_ value: Any?) -> Double {
        switch value {
        case let value as Double: value
        case let value as Int64: Double(value)
        default: 0
        }
    }

    private static func jsonData(_ value: Any?) -> Data? {
        switch value {
        case let text as String: Data(text.utf8)
        case let data as Data: data
        default: nil
        }
    }

    /// `{"id":"claude-sonnet-5","providerID":"anthropic"}` -> `claude-sonnet-5`.
    static func modelID(fromJSON json: String) -> String? {
        struct Model: Decodable { let id: String }
        return (try? JSONDecoder().decode(Model.self, from: Data(json.utf8)))?.id
    }
}
