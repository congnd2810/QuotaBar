import Foundation
import Testing
@testable import DeskAppCore

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("provider-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func sqlite(_ db: URL, _ sql: String) async throws {
    let result = try await ProcessRunner.run("/usr/bin/sqlite3", [db.path], stdin: Data(sql.utf8))
    #expect(result.status == 0, "\(String(decoding: result.stderr, as: UTF8.self))")
}

struct CommandCodeTests {
    // Shapes captured from api.commandcode.ai (ids removed).
    let credits = #"{"credits":{"belowThreshold":false,"creditThreshold":0,"monthlyCredits":43.0531899796,"purchasedCredits":0,"freeCredits":0},"windowLimits":{"limited":true,"exceeded":null,"fiveHour":{"used":7,"cap":14,"exceeded":false,"resetAt":1793491200000},"weekly":{"used":0,"cap":35,"exceeded":false,"resetAt":0}},"sandboxAccess":true}"#
    let subscription = #"{"success":true,"data":{"status":"active","cancelAtPeriodEnd":false,"currentPeriodStart":"2026-09-18T09:31:59.000Z","currentPeriodEnd":"2026-10-18T09:31:59.000Z","cancelAt":"2026-10-18T09:31:59.000Z","planId":"individual-goat"}}"#

    @Test func usesPlanPoolLikeTheCLI() throws {
        let usage = try CommandCodeFetcher.parse(credits: Data(credits.utf8), subscription: Data(subscription.utf8))
        #expect(usage.planName == "GOAT")
        #expect(usage.endsAtPeriodEnd)
        #expect(usage.group.windows.map(\.id) == ["monthly", "five_hour", "weekly"])
        // (70 - 43.05) / 70
        #expect(abs(usage.group.windows[0].usedFraction - (70 - 43.0531899796) / 70) < 1e-9)
        #expect(usage.group.windows[1].usedFraction == 0.5)
        #expect(usage.group.windows[1].resetsAt == Date(timeIntervalSince1970: 1_793_491_200))
        #expect(usage.group.windows[2].resetsAt == nil) // resetAt 0: window not started
    }

    @Test func readsSessionsWithTitleAndCost() throws {
        let project = try tempDir().appendingPathComponent("volumes-code-film")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"session","version":3,"id":"s-1","timestamp":"2026-10-15T01:00:00.000Z","cwd":"/code/film"}"#,
            #"{"type":"message","timestamp":"2026-10-15T01:01:00.000Z","usage":{"inputTokens":10,"outputTokens":2,"costUsd":0.25},"model":"deepseek/x"}"#,
            #"{"type":"message","timestamp":"2026-10-15T01:05:00.000Z","usage":{"costUsd":0.5},"model":"deepseek/x"}"#,
        ]
        try lines.joined(separator: "\n").write(to: project.appendingPathComponent("s-1.jsonl"), atomically: true, encoding: .utf8)
        try #"{"title":"Add Git Remote"}"#.write(to: project.appendingPathComponent("s-1.meta.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: project.appendingPathComponent("s-1.checkpoints.jsonl"), atomically: true, encoding: .utf8)

        let sessions = CommandCodeSessionReader.read(directory: project.deletingLastPathComponent(), since: .distantPast)
        #expect(sessions.count == 1)
        #expect(sessions[0].title == "Add Git Remote")
        #expect(sessions[0].projectPath == "/code/film")
        #expect(sessions[0].cost == 0.75)
        #expect(sessions[0].lastActivity == ISO8601Parser().parse("2026-10-15T01:05:00.000Z"))
    }
}

struct CodexTests {
    let line = #"{"timestamp":"2026-09-07T06:42:28.503Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":99.0,"window_minutes":300,"resets_at":1788779371},"secondary":{"used_percent":44.0,"window_minutes":10080,"resets_at":1789211182},"plan_type":"plus"}}}"#

    @Test func parsesRateLimitsAndResetsStaleWindows() throws {
        let limits = try #require(CodexReader.parseLimits(Data(line.utf8)))
        #expect(limits.planType == "plus")
        #expect(limits.group.windows.map(\.title) == ["5 hours", "Weekly"])
        #expect(limits.group.windows.map(\.usedFraction) == [0.99, 0.44])

        // Between the two resets: the 5-hour window has reset, the weekly one has not.
        let current = limits.current(at: Date(timeIntervalSince1970: 1_789_000_000))
        #expect(current.group.windows.map(\.usedFraction) == [0, 0.44])
    }

    @Test func nullLimitsAreIgnored() {
        let apiKeyLine = #"{"timestamp":"2026-10-09T02:21:11.274Z","payload":{"rate_limits":{"primary":null,"secondary":null}}}"#
        #expect(CodexReader.parseLimits(Data(apiKeyLine.utf8)) == nil)
    }

    @Test func readsInteractiveSessionsWithThreadNames() throws {
        let home = try tempDir()
        let day = home.appendingPathComponent("sessions/2026/10/15")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        func write(_ name: String, _ lines: [String]) throws {
            try lines.joined(separator: "\n").write(to: day.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try write("rollout-a.jsonl", [
            #"{"timestamp":"2026-10-15T01:00:00Z","type":"session_meta","payload":{"id":"t-1","cwd":"/code/app","source":"cli"}}"#,
            #"{"timestamp":"2026-10-15T01:02:00Z","type":"turn_context","payload":{"model":"gpt-x","cwd":"/code/app"}}"#,
            #"{"timestamp":"2026-10-15T01:03:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":1234}}}}"#,
        ])
        try write("rollout-b.jsonl", [
            #"{"timestamp":"2026-10-15T02:00:00Z","type":"session_meta","payload":{"id":"t-2","cwd":"/tmp","source":"exec"}}"#,
        ])
        try #"{"id":"t-1","thread_name":"Fix login","updated_at":"2026-10-15T01:03:00Z"}"#
            .write(to: home.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)

        let sessions = CodexReader.sessions(home: home, since: .distantPast)
        #expect(sessions.map(\.id) == ["t-1"]) // exec runs are skipped
        #expect(sessions[0].title == "Fix login")
        #expect(sessions[0].totalTokens == 1234)
        #expect(sessions[0].model == "gpt-x")
    }
}

struct CursorTests {
    @Test func parsesUsageSummary() throws {
        let json = #"{"billingCycleStart":"2026-10-01T00:00:00.000Z","billingCycleEnd":"2026-11-01T00:00:00.000Z","membershipType":"pro","individualUsage":{"plan":{"enabled":true,"used":1500,"limit":2000,"remaining":500,"totalPercentUsed":75},"onDemand":{"enabled":true,"used":250,"limit":1000}}}"#
        let usage = try CursorFetcher.parse(Data(json.utf8))
        #expect(usage.membership == "pro")
        #expect(usage.group.windows.map(\.id) == ["plan", "on_demand"])
        #expect(usage.group.windows.map(\.usedFraction) == [0.75, 0.25])
        #expect(usage.group.windows[0].resetsAt == ISO8601Parser().parse("2026-11-01T00:00:00.000Z"))
    }

    @Test func fallsBackToUsedOverLimitAndSkipsUnlimitedOnDemand() throws {
        let json = #"{"individualUsage":{"plan":{"enabled":true,"used":500,"limit":2000},"onDemand":{"enabled":true,"used":10,"limit":null}}}"#
        let usage = try CursorFetcher.parse(Data(json.utf8))
        #expect(usage.group.windows.map(\.usedFraction) == [0.25])
    }

    @Test func readsUserIDAndExpiryFromJWT() throws {
        func base64url(_ s: String) -> String {
            Data(s.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let token = "x." + base64url(#"{"sub":"auth0|user_ABC","exp":1800000000}"#) + ".sig"
        let claims = try #require(CursorFetcher.jwtClaims(token))
        #expect(claims.userID == "user_ABC")
        #expect(claims.expiry == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func readsTokenFromStateDatabase() async throws {
        let db = try tempDir().appendingPathComponent("state.vscdb")
        try await sqlite(db, "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB); INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', 'tok.en.x');")
        #expect(try CursorFetcher.accessToken(database: db) == "tok.en.x")
    }
}

struct OpenCodeTests {
    @Test func readsSessionV2() async throws {
        let db = try tempDir().appendingPathComponent("opencode.db")
        try await sqlite(db, """
            CREATE TABLE session_v2 (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT NOT NULL, title TEXT, model TEXT,
              cost REAL, tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER, tokens_cache_read INTEGER,
              tokens_cache_write INTEGER, time_created INTEGER, time_updated INTEGER, time_archived INTEGER);
            INSERT INTO session_v2 VALUES
              ('ses_new', NULL, '/code/app', 'Fix bug', '{"id":"claude-sonnet-5","providerID":"anthropic"}', 1.5, 100, 20, 5, 1000, 50, 0, 1792000000000, NULL),
              ('ses_child', 'ses_new', '/code/app', 'sub', NULL, 0.1, 1, 1, 0, 0, 0, 0, 1792000000001, NULL),
              ('ses_arch', NULL, '/code/app', 'old', NULL, 0.1, 1, 1, 0, 0, 0, 0, 1792000000002, 1792000000003),
              ('ses_old', NULL, '/code/app', 'older', NULL, 0.1, 1, 1, 0, 0, 0, 0, 1000, NULL);
            """)
        let sessions = try OpenCodeReader.sessions(database: db, since: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(sessions.map(\.id) == ["ses_new"])
        #expect(sessions[0].cost == 1.5)
        #expect(sessions[0].totalTokens == 1175)
        #expect(sessions[0].model == "claude-sonnet-5")
        #expect(sessions[0].lastActivity == Date(timeIntervalSince1970: 1_792_000_000))
    }

    @Test func readsLegacyTables() async throws {
        let db = try tempDir().appendingPathComponent("opencode.db")
        try await sqlite(db, """
            CREATE TABLE session (id TEXT, data TEXT);
            CREATE TABLE message (id TEXT, data TEXT);
            INSERT INTO session VALUES ('ses_1', '{"id":"ses_1","title":"Old","directory":"/w","time":{"created":1,"updated":1792000000000}}');
            INSERT INTO message VALUES ('m1', '{"sessionID":"ses_1","role":"assistant","cost":0.2,"modelID":"gpt-x","tokens":{"input":10,"output":5,"reasoning":0,"cache":{"read":1,"write":0}}}');
            INSERT INTO message VALUES ('m2', '{"sessionID":"ses_1","role":"user"}');
            """)
        let sessions = try OpenCodeReader.sessions(database: db, since: .distantPast)
        #expect(sessions.count == 1)
        #expect(sessions[0].cost == 0.2)
        #expect(sessions[0].totalTokens == 16)
        #expect(sessions[0].model == "gpt-x")
    }
}
