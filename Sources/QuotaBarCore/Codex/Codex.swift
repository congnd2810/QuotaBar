import Foundation

/// Codex (OpenAI) plan limits as last recorded in its session logs. Codex writes `rate_limits` with
/// every token count while signed in with a ChatGPT plan; with an API key the fields are null and
/// the newest non-null snapshot is reported with its date.
public struct CodexLimits: Sendable, Equatable {
    public let group: LimitGroup
    public let planType: String?
    public let recordedAt: Date

    /// Windows whose reset time has passed since the snapshot are shown as reset (0%): any later
    /// plan usage would have written a newer snapshot to the logs.
    public func current(at now: Date = Date()) -> CodexLimits {
        let windows = group.windows.map { window in
            guard let resetsAt = window.resetsAt, resetsAt <= now else { return window }
            return UsageWindow(id: window.id, title: window.title, usedFraction: 0, resetsAt: nil)
        }
        return CodexLimits(group: LimitGroup(id: group.id, title: group.title, windows: windows),
                           planType: planType, recordedAt: recordedAt)
    }
}

public enum CodexReader {
    public static var home: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"] { return URL(fileURLWithPath: custom) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent("sessions").path)
    }

    /// Scans the most recent session files (newest first) for the latest rate-limit snapshot.
    public static func latestLimits(home: URL = home, maxFiles: Int = 60) -> CodexLimits? {
        let files = JSONLines.files(under: home.appendingPathComponent("sessions"), suffix: ".jsonl", modifiedSince: .distantPast)
        for file in files.prefix(maxFiles) {
            var latest: CodexLimits?
            JSONLines.forEach(file.url, containing: ["\"rate_limits\"", "\"primary\":{"]) { line in
                if let limits = parseLimits(line) { latest = limits }
            }
            if let latest { return latest }
        }
        return nil
    }

    static func parseLimits(_ line: Data) -> CodexLimits? {
        struct Window: Decodable {
            let usedPercent: Double
            let windowMinutes: Double?
            let resetsAt: Double?
        }
        struct Line: Decodable {
            struct Payload: Decodable {
                struct Limits: Decodable {
                    let primary: Window?
                    let secondary: Window?
                    let planType: String?
                }
                let rateLimits: Limits?
            }
            let timestamp: String?
            let payload: Payload?
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let line = try? decoder.decode(Line.self, from: line),
              let limits = line.payload?.rateLimits,
              let recordedAt = line.timestamp.flatMap(ISO8601Parser().parse)
        else { return nil }
        let windows = [("primary", limits.primary), ("secondary", limits.secondary)].compactMap { id, window -> UsageWindow? in
            guard let window else { return nil }
            return UsageWindow(
                id: id,
                title: title(minutes: window.windowMinutes),
                usedFraction: min(max(window.usedPercent / 100, 0), 1),
                resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) }
            )
        }
        guard !windows.isEmpty else { return nil }
        return CodexLimits(group: LimitGroup(id: "codex", title: "Codex", windows: windows),
                           planType: limits.planType, recordedAt: recordedAt)
    }

    static func title(minutes: Double?) -> String {
        switch minutes {
        case 300: "5 hours"
        case 10080: "Weekly"
        case let minutes?: "\(Int(minutes / 60)) hours"
        case nil: "Limit"
        }
    }

    /// Interactive Codex sessions (CLI and desktop) of the scan window. `exec` runs started by
    /// scripts/SDKs are skipped: they live in temporary folders and are not meant to be resumed.
    public static func sessions(home: URL = home, since cutoff: Date) -> [CodexSession] {
        struct Meta: Decodable {
            struct Payload: Decodable {
                let id: String
                let cwd: String?
                let source: String?
            }
            let type: String
            let payload: Payload
        }
        struct TokenLine: Decodable {
            struct Payload: Decodable {
                struct Info: Decodable {
                    struct Usage: Decodable { let totalTokens: Int? }
                    let totalTokenUsage: Usage?
                }
                let info: Info?
                let model: String?
            }
            let timestamp: String?
            let payload: Payload?
        }
        let titles = threadNames(home: home)
        let parser = ISO8601Parser()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        return JSONLines.files(under: home.appendingPathComponent("sessions"), suffix: ".jsonl", modifiedSince: cutoff)
            .compactMap { file -> CodexSession? in
                var meta: Meta.Payload?
                var tokens = 0
                var model: String?
                var last: Date?
                JSONLines.forEach(file.url) { data in
                    if meta == nil, let line = try? decoder.decode(Meta.self, from: data), line.type == "session_meta" {
                        meta = line.payload
                        return
                    }
                    guard let line = try? decoder.decode(TokenLine.self, from: data) else { return }
                    if let ts = line.timestamp.flatMap(parser.parse) { last = ts }
                    if let total = line.payload?.info?.totalTokenUsage?.totalTokens { tokens = total }
                    if let lineModel = line.payload?.model { model = lineModel }
                }
                guard let meta, let cwd = meta.cwd, meta.source != "exec" else { return nil }
                return CodexSession(id: meta.id, title: titles[meta.id], projectPath: cwd,
                                    lastActivity: last ?? file.modified, totalTokens: tokens, model: model)
            }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Thread names from `session_index.jsonl` (renamed or auto-titled threads); later lines win.
    static func threadNames(home: URL) -> [String: String] {
        struct Entry: Decodable {
            let id: String
            let threadName: String?
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var names: [String: String] = [:]
        JSONLines.forEach(home.appendingPathComponent("session_index.jsonl")) { data in
            if let entry = try? decoder.decode(Entry.self, from: data), let name = entry.threadName, !name.isEmpty {
                names[entry.id] = name
            }
        }
        return names
    }
}

public struct CodexSession: Sendable, Identifiable {
    public let id: String
    public let title: String?
    public let projectPath: String
    public let lastActivity: Date
    public let totalTokens: Int
    public let model: String?
}
