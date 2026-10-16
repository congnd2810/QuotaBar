import Foundation
import Testing
@testable import QuotaBarCore

struct LimitHistoryTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    private let claude = [LimitGroup(id: "claude", title: "Claude", windows: [
        UsageWindow(id: "five_hour", title: "5 hours", usedFraction: 0.1, resetsAt: nil),
    ])]

    @Test func keepsSevenCalendarDaysIncludingToday() {
        var history = LimitHistory()
        history.record(provider: "claude", groups: claude, at: date(7, 23))  // 8 days ago (inclusive count) -> dropped
        history.record(provider: "claude", groups: claude, at: date(8, 0))   // first day of the window -> kept
        history.record(provider: "claude", groups: claude, at: date(14, 12)) // today
        history.prune(now: date(14, 15), calendar: calendar)
        #expect(history.samples.map(\.date) == [date(8, 0), date(14, 12)])

        // The next day the window moves forward by one day.
        history.prune(now: date(15, 1), calendar: calendar)
        #expect(history.samples.map(\.date) == [date(14, 12)])
    }

    @Test func seriesTitlesIncludeGroupOnlyWhenNeeded() {
        var history = LimitHistory()
        history.record(provider: "claude", groups: claude, at: date(14, 1))
        history.record(provider: "antigravity", groups: [
            LimitGroup(id: "Gemini", title: "Gemini", windows: [UsageWindow(id: "gemini-5h", title: "5 hours", usedFraction: 0.5, resetsAt: nil)]),
            LimitGroup(id: "3p", title: "Claude and GPT", windows: [UsageWindow(id: "3p-5h", title: "5 hours", usedFraction: 0.2, resetsAt: nil)]),
        ], at: date(14, 1))
        #expect(history.samples(for: "claude").map(\.seriesTitle) == ["5 hours"])
        #expect(history.samples(for: "antigravity").map(\.seriesTitle) == ["Gemini · 5 hours", "Claude and GPT · 5 hours"])
        #expect(history.samples(for: "antigravity").map(\.seriesID) == ["antigravity/Gemini/gemini-5h", "antigravity/3p/3p-5h"])
    }
}

struct CSVExporterTests {
    @Test func escapesSpecialCharacters() {
        #expect(CSVExporter.escape("plain") == "plain")
        #expect(CSVExporter.escape("a,b") == "\"a,b\"")
        #expect(CSVExporter.escape("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(CSVExporter.render([["a", "b,c"], ["1", "2"]]) == "a,\"b,c\"\n1,2\n")
    }

    @Test func limitHistoryHasHeaderAndPercent() {
        var history = LimitHistory()
        history.record(provider: "claude", groups: [LimitGroup(id: "claude", title: "Claude", windows: [
            UsageWindow(id: "seven_day", title: "7 days", usedFraction: 0.345, resetsAt: nil),
        ])], at: Date(timeIntervalSince1970: 0))
        let lines = CSVExporter.limitHistory(history).split(separator: "\n")
        #expect(lines.first == "timestamp,provider,series_id,series,used_percent")
        #expect(lines.last == "1970-01-01T00:00:00Z,claude,claude/claude/seven_day,7 days,34.5")
    }
}

struct ResumeCommandTests {
    @Test func quotesPathsWithSpacesAndQuotes() {
        #expect(ResumeCommand.claude(sessionID: "abc-123", projectPath: "/Users/me/My App's") ==
            #"cd '/Users/me/My App'\''s' && claude --resume 'abc-123'"#)
        #expect(ResumeCommand.agy(conversationID: "c-1", projectPath: "/w") == "cd '/w' && agy --conversation 'c-1'")
    }

    @Test func quotedPathSurvivesTheShell() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar it's $HOME `x`")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let command = ResumeCommand.claude(sessionID: "s", projectPath: dir.path)
            .replacingOccurrences(of: "claude --resume 's'", with: "pwd")
        let output = try await ProcessRunner.run("/bin/sh", ["-c", command])
        #expect(String(decoding: output.stdout, as: UTF8.self) == dir.path + "\n")
    }
}

struct AgySessionReaderTests {
    @Test func readsTopLevelConversationsFromSQLite() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = dir.appendingPathComponent("conversation_summaries.db")
        // Same columns agy uses (subset), filled via the sqlite3 CLI.
        let sql = """
            CREATE TABLE conversation_summaries (conversation_id text, title text NOT NULL DEFAULT "", preview text NOT NULL DEFAULT "",
              step_count integer NOT NULL DEFAULT 0, last_modified_time datetime NOT NULL, workspace_uris text NOT NULL,
              nesting_depth integer NOT NULL DEFAULT 0);
            INSERT INTO conversation_summaries VALUES
              ('new', 'Fix bug', '', 12, '2026-10-14 10:17:40.490647+00:00', '["file:///Volumes/code/My%20Game"]', 0),
              ('sub', '', '', 3, '2026-10-14 10:18:00.000000+00:00', '["file:///Volumes/code/My%20Game"]', 1),
              ('untitled', '', 'Hello there', 5, '2026-10-13 09:00:00.000000+00:00', '["file:///w"]', 0),
              ('old', 'Old', '', 1, '2026-08-01 00:00:00.000000+00:00', '["file:///w"]', 0);
            """
        let result = try await ProcessRunner.run("/usr/bin/sqlite3", [db.path], stdin: Data(sql.utf8))
        #expect(result.status == 0)

        let cutoff = try #require(ISO8601Parser().parse("2026-09-15T00:00:00Z"))
        let sessions = try AgySessionReader.read(database: db, since: cutoff)
        #expect(sessions.map(\.id) == ["new", "untitled"])
        #expect(sessions[0].projectPath == "/Volumes/code/My Game")
        #expect(sessions[0].stepCount == 12)
        #expect(sessions[1].title == "Hello there") // falls back to the preview
    }

    @Test func missingDatabaseMeansNoSessions() throws {
        let missing = URL(fileURLWithPath: "/nonexistent/conversation_summaries.db")
        #expect(try AgySessionReader.read(database: missing, since: .distantPast).isEmpty)
    }
}
