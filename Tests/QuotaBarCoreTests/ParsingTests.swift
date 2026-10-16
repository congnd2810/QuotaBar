import Foundation
import Testing
@testable import QuotaBarCore

struct ParsingTests {
    @Test func claudeLimitsParsesWindowsAndSkipsNulls() throws {
        let json = """
        {"five_hour":{"utilization":5.0,"resets_at":"2026-10-14T11:59:59.521067+00:00","limit_dollars":null},
         "seven_day":{"utilization":34.0,"resets_at":"2026-10-16T14:59:59.521094+00:00"},
         "seven_day_opus":null,"seven_day_sonnet":null,"cedar_ember":{"x":1},"extra_usage":{"is_enabled":false}}
        """
        let group = try ClaudeLimitsFetcher.parse(Data(json.utf8))
        #expect(group.windows.map(\.id) == ["five_hour", "seven_day"])
        #expect(group.windows[0].usedFraction == 0.05)
        #expect(group.windows[1].usedFraction == 0.34)
        let expected = try #require(ISO8601Parser().parse("2026-10-14T11:59:59Z"))
        let resetsAt = try #require(group.windows[0].resetsAt)
        #expect(abs(resetsAt.timeIntervalSince(expected)) < 1)
    }

    @Test func iso8601ParserHandlesMillisMicrosAndPlain() {
        let parser = ISO8601Parser()
        #expect(parser.parse("2026-10-14T07:08:47.379Z") != nil)
        #expect(parser.parse("2026-10-14T11:59:59.521067+00:00") != nil)
        #expect(parser.parse("2026-10-19T14:26:13Z") != nil)
        #expect(parser.parse("not a date") == nil)
    }

    @Test func antigravityParsesGroupsAsUsedFraction() throws {
        let json = """
        {"conversation_id":"","status":"SUCCESS","response":"…","command":{"name":"usage","data":{"groups":[
          {"name":"Gemini Models","buckets":[
            {"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":0.96,"reset_time":"2026-10-19T14:26:13Z"},
            {"id":"gemini-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":0.88,"reset_time":"2026-10-14T10:47:03Z"}]},
          {"name":"Claude and GPT models","buckets":[
            {"id":"3p-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":1,"reset_time":"2026-10-14T12:29:12Z"}]}]}}}
        """
        let groups = try AntigravityQuotaFetcher.parse(Data(json.utf8))
        #expect(groups.map(\.title) == ["Gemini Models", "Claude and GPT models"])
        #expect(groups[0].windows.map(\.title) == ["Weekly", "5 hours"])
        #expect(abs(groups[0].windows[0].usedFraction - 0.04) < 1e-9)
        #expect(groups[1].windows[0].usedFraction == 0)

        let summary = AntigravityQuotaFetcher.summaryFractions(for: groups)
        #expect(abs((summary.gemini ?? 0) - 0.12) < 1e-9)
        #expect(summary.external == 0)
        #expect(AntigravityQuotaFetcher.summaryFractions(for: []) == (nil, nil))
    }

    @Test func antigravityRejectsFailedStatus() {
        let json = #"{"status":"ERROR","response":"not signed in"}"#
        #expect(throws: AntigravityQuotaFetcher.FetchError.self) {
            try AntigravityQuotaFetcher.parse(Data(json.utf8))
        }
    }

    @Test func credentialTokenReadsOAuthSection() throws {
        let json: [String: Any] = [
            "mcpOAuth": ["x": ["accessToken": "mcp"]],
            "claudeAiOauth": [
                "accessToken": "at", "refreshToken": "rt", "expiresAt": 1_791_991_052_623,
                "scopes": ["user:inference", "user:profile"],
            ],
        ]
        let token = try ClaudeCredentialStore.token(from: json)
        #expect(token.accessToken == "at")
        #expect(token.scopes == ["user:inference", "user:profile"])
        #expect(token.expiresAt == Date(timeIntervalSince1970: 1_791_991_052.623))
        #expect(throws: ClaudeCredentialStore.CredentialError.self) {
            try ClaudeCredentialStore.token(from: ["mcpOAuth": [:]])
        }
    }

    @Test func hexDecoding() {
        #expect(Data(hexString: "7b7d") == Data("{}".utf8))
        #expect(Data(hexString: "7b7") == nil)
        #expect(Data(hexString: "zz") == nil)
    }
}
