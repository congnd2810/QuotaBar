import Foundation
import Testing
@testable import QuotaBarCore

struct PricingTests {
    @Test func normalizeStripsContextTagAndDate() {
        #expect(ModelPricing.normalize("claude-opus-5-5[1m]") == "claude-opus-5-5")
        #expect(ModelPricing.normalize("claude-haiku-4-5-20251001") == "claude-haiku-4-5")
        #expect(ModelPricing.normalize("claude-opus-5") == "claude-opus-5")
    }

    @Test func opus55CostUsesCacheMultipliers() throws {
        // 1M of each kind: input 4 + 5m write 5 + 1h write 8 + read 0.20 + output 20.
        let tokens = TokenCounts(input: 1_000_000, output: 1_000_000, cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000, cacheRead: 1_000_000)
        let cost = try #require(ModelPricing.cost(model: "claude-opus-5-5", tokens: tokens))
        #expect(abs(cost - 37.20) < 1e-9)
    }

    @Test func haikuLongPromptSwitchesRateCard() throws {
        let short = try #require(ModelPricing.cost(model: "claude-haiku-5-5", tokens: TokenCounts(input: 100_000)))
        let long = try #require(ModelPricing.cost(model: "claude-haiku-5-5", tokens: TokenCounts(input: 100_001)))
        #expect(abs(short - 0.01) < 1e-9)
        #expect(abs(long - 100_001 * 0.50 / 1_000_000) < 1e-9)
    }

    @Test func unknownModelHasNoPrice() {
        #expect(ModelPricing.cost(model: "opus", tokens: TokenCounts(input: 10)) == nil)
    }
}

struct UsageScannerTests {
    private static func assistantLine(id: String, request: String, model: String = "claude-opus-5-5",
                                      timestamp: String, input: Int, output: Int, write5m: Int = 0, write1h: Int = 0, read: Int = 0) -> String {
        """
        {"type":"assistant","timestamp":"\(timestamp)","sessionId":"s1","requestId":"\(request)","message":{"id":"\(id)","model":"\(model)","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":\(input),"cache_creation_input_tokens":\(write5m + write1h),"cache_read_input_tokens":\(read),"output_tokens":\(output),"cache_creation":{"ephemeral_1h_input_tokens":\(write1h),"ephemeral_5m_input_tokens":\(write5m)}}}}
        """
    }

    private func makeProjectDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-tests-\(UUID().uuidString)/projects/-tmp-proj")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func dedupesStreamedMessagesAndSkipsNonUsageLines() async throws {
        let dir = try makeProjectDir()
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let lines = [
            #"{"type":"user","timestamp":"\#(ts)","message":{"role":"user","content":"hello"}}"#,
            // Same message written twice while streaming: only the last line counts.
            Self.assistantLine(id: "m1", request: "r1", timestamp: ts, input: 10, output: 5),
            Self.assistantLine(id: "m1", request: "r1", timestamp: ts, input: 10, output: 50, write5m: 100, write1h: 30, read: 1000),
            Self.assistantLine(id: "m2", request: "r2", model: "<synthetic>", timestamp: ts, input: 1, output: 1),
            Self.assistantLine(id: "m3", request: "r3", model: "opus", timestamp: ts, input: 7, output: 3),
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)

        let scanner = ClaudeCodeUsageScanner(roots: [dir.deletingLastPathComponent()])
        let summary = await scanner.scan(now: now)

        let opus = try #require(summary.daily.first { $0.model == "claude-opus-5-5" })
        #expect(opus.tokens == TokenCounts(input: 10, output: 50, cacheWrite5m: 100, cacheWrite1h: 30, cacheRead: 1000))
        let expected = (10 * 4.0 + 100 * 5.0 + 30 * 8.0 + 1000 * 0.20 + 50 * 20.0) / 1_000_000
        #expect(abs(opus.cost - expected) < 1e-12)
        #expect(summary.unpricedModels == ["opus"])
        #expect(!summary.daily.contains { $0.model == "<synthetic>" })
    }

    @Test func readsOnlyAppendedCompleteLinesAndPersistsCache() async throws {
        let dir = try makeProjectDir()
        let file = dir.appendingPathComponent("b.jsonl")
        let cacheURL = dir.deletingLastPathComponent().appendingPathComponent("cache.json")
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)

        let first = Self.assistantLine(id: "m1", request: "r1", timestamp: ts, input: 100, output: 0)
        let second = Self.assistantLine(id: "m2", request: "r2", timestamp: ts, input: 200, output: 0)
        // Second line has no trailing newline yet: it is still being written.
        try (first + "\n" + second).write(to: file, atomically: true, encoding: .utf8)

        let scanner = ClaudeCodeUsageScanner(roots: [dir.deletingLastPathComponent()], cacheURL: cacheURL)
        #expect(await scanner.scan(now: now).tokens(since: .distantPast) == 100)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()
        #expect(await scanner.scan(now: now).tokens(since: .distantPast) == 300)

        // A fresh scanner restores state from the cache: overwrite the log with same-size junk,
        // which would parse to nothing if it were re-read.
        let size = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        try Data(repeating: UInt8(ascii: " "), count: size).write(to: file)
        let restored = ClaudeCodeUsageScanner(roots: [dir.deletingLastPathComponent()], cacheURL: cacheURL)
        #expect(await restored.scan(now: now).tokens(since: .distantPast) == 300)
    }

    @Test func groupsSessionsWithSubagentsAndTitles() async throws {
        let dir = try makeProjectDir()
        let now = Date()
        let iso = ISO8601DateFormatter()
        let early = iso.string(from: now.addingTimeInterval(-3600)), late = iso.string(from: now)
        func line(_ id: String, _ session: String, _ ts: String, _ input: Int) -> String {
            #"{"type":"assistant","timestamp":"\#(ts)","sessionId":"\#(session)","cwd":"/work/app","requestId":"r-\#(id)","message":{"id":"\#(id)","model":"claude-opus-5-5","usage":{"input_tokens":\#(input),"output_tokens":0}}}"#
        }
        let main = [
            #"{"type":"ai-title","aiTitle":"no-conversation-content","sessionId":"s1"}"#,
            line("a", "s1", early, 100),
            #"{"type":"ai-title","aiTitle":"Fix login","sessionId":"s1"}"#,
        ]
        try (main.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
        // Subagent logs live in <session>/subagents and carry the parent's session id.
        let sub = dir.appendingPathComponent("s1/subagents")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try (line("b", "s1", late, 50) + "\n").write(to: sub.appendingPathComponent("agent-x.jsonl"), atomically: true, encoding: .utf8)
        try (line("c", "s2", early, 7) + "\n").write(to: dir.appendingPathComponent("s2.jsonl"), atomically: true, encoding: .utf8)

        let summary = await ClaudeCodeUsageScanner(roots: [dir.deletingLastPathComponent()]).scan(now: now)
        #expect(summary.sessions.map(\.id) == ["s1", "s2"]) // most recent activity first
        let s1 = try #require(summary.sessions.first)
        #expect(s1.title == "Fix login")
        #expect(s1.tokens.input == 150)
        #expect(s1.projectPath == "/work/app")
        #expect(s1.projectName == "app")
        #expect(summary.sessions[1].title == nil)
    }

    @Test func dropsEntriesOlderThanLookback() async throws {
        let dir = try makeProjectDir()
        let now = Date()
        let old = ISO8601DateFormatter().string(from: now.addingTimeInterval(-40 * 86_400))
        let recent = ISO8601DateFormatter().string(from: now)
        let lines = [
            Self.assistantLine(id: "old", request: "r0", timestamp: old, input: 999, output: 0),
            Self.assistantLine(id: "new", request: "r1", timestamp: recent, input: 1, output: 0),
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("c.jsonl"), atomically: true, encoding: .utf8)
        let scanner = ClaudeCodeUsageScanner(roots: [dir.deletingLastPathComponent()], lookbackDays: 30)
        #expect(await scanner.scan(now: now).tokens(since: .distantPast) == 1)
    }
}
