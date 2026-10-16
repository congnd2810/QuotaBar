import Foundation

/// Reads Antigravity quotas through the `agy` CLI (`agy -p /usage --output-format json`).
/// `/usage` is a slash command handled locally, so it does not consume any quota.
public struct AntigravityQuotaFetcher: Sendable {
    public enum FetchError: LocalizedError {
        case cliNotFound
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .cliNotFound: "`agy` not found. Install the Antigravity CLI or check ~/.local/bin/agy."
            case .failed(let message): "agy /usage failed: \(message)"
            }
        }
    }

    public init() {}

    public static func locateCLI() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func fetch() async throws -> [LimitGroup] {
        guard let cli = Self.locateCLI() else { throw FetchError.cliNotFound }
        let result = try await ProcessRunner.run(
            cli,
            ["-p", "/usage", "--output-format", "json"],
            workingDirectory: FileManager.default.temporaryDirectory,
            timeout: 45
        )
        guard result.status == 0 else {
            throw FetchError.failed(String(decoding: result.stderr.prefix(300), as: UTF8.self))
        }
        return try Self.parse(result.stdout)
    }

    static func parse(_ data: Data) throws -> [LimitGroup] {
        struct Bucket: Decodable {
            let id: String
            let name: String?
            let window: String?
            let remainingFraction: Double?
            let resetTime: String?
        }
        struct Group: Decodable {
            let name: String
            let buckets: [Bucket]
        }
        struct Response: Decodable {
            struct Command: Decodable {
                struct Payload: Decodable { let groups: [Group] }
                let data: Payload?
            }
            let status: String?
            let response: String?
            let command: Command?
        }

        // Tolerate log noise before the JSON object.
        let json = data.firstIndex(of: UInt8(ascii: "{")).map { data[$0...] } ?? data
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(Response.self, from: Data(json))
        guard response.status == "SUCCESS", let groups = response.command?.data?.groups else {
            throw FetchError.failed(response.response ?? response.status ?? "no data")
        }

        let parser = ISO8601Parser()
        return groups.map { group in
            LimitGroup(
                id: group.name,
                title: group.name,
                windows: group.buckets.map { bucket in
                    UsageWindow(
                        id: bucket.id,
                        title: title(for: bucket.window) ?? bucket.name ?? bucket.id,
                        usedFraction: 1 - (bucket.remainingFraction ?? 1),
                        resetsAt: bucket.resetTime.flatMap(parser.parse)
                    )
                }
            )
        }
    }

    /// True for Google's own Gemini model group (as opposed to external Claude/GPT models).
    public static func isGemini(_ group: LimitGroup) -> Bool {
        group.id.localizedCaseInsensitiveContains("gemini")
            || group.windows.contains { $0.id.hasPrefix("gemini") }
    }

    /// Most constrained window fraction for Google's Gemini models and for external models.
    public static func summaryFractions(for groups: [LimitGroup]) -> (gemini: Double?, external: Double?) {
        let gemini = groups.filter(isGemini).compactMap(\.maxUsedFraction).max()
        let external = groups.filter { !isGemini($0) }.compactMap(\.maxUsedFraction).max()
        return (gemini, external)
    }

    private static func title(for window: String?) -> String? {
        switch window {
        case "5h": "5 hours"
        case "weekly": "Weekly"
        default: nil
        }
    }
}
