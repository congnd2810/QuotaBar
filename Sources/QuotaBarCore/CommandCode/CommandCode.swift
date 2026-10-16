import Foundation

/// Plan usage of Command Code (commandcode.ai), from the same endpoints its `/usage` command calls.
public struct CommandCodeUsage: Sendable, Equatable {
    public let group: LimitGroup
    public let planName: String?
    public let creditsRemaining: Double
    public let periodEnd: Date?
    /// The subscription was cancelled and ends at `periodEnd`.
    public let endsAtPeriodEnd: Bool
}

public struct CommandCodeFetcher: Sendable {
    public enum FetchError: LocalizedError {
        case notSignedIn
        case http(String, Int)

        public var errorDescription: String? {
            switch self {
            case .notSignedIn: "Not signed in to Command Code. Run `commandcode login`."
            case .http(let endpoint, let code): "Command Code API error \(code) (\(endpoint))"
            }
        }
    }

    static let baseURL = URL(string: "https://api.commandcode.ai")!

    /// Monthly credits per plan id prefix, as in Command Code's CLI (longest prefix wins).
    static let planCredits: [String: Double] = [
        "individual-go": 10, "individual-go-v1": 10, "individual-goat": 70, "individual-pro": 30,
        "individual-pro-v1": 80, "individual-provider": 15, "individual-max": 150, "individual-ultra": 300,
        "teams-pro": 40,
    ]
    static let planNames: [String: String] = [
        "individual-go": "Go", "individual-go-v1": "Go", "individual-goat": "GOAT", "individual-pro": "Pro",
        "individual-pro-v1": "Pro", "individual-provider": "Provider", "individual-max": "Max",
        "individual-ultra": "Ultra", "teams-pro": "Teams Pro",
    ]

    public static var authFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".commandcode/auth.json")
    }

    public static var isInstalled: Bool { FileManager.default.fileExists(atPath: authFile.path) }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch() async throws -> CommandCodeUsage {
        struct Auth: Decodable { let apiKey: String }
        guard let data = try? Data(contentsOf: Self.authFile),
              let apiKey = try? JSONDecoder().decode(Auth.self, from: data).apiKey
        else { throw FetchError.notSignedIn }

        async let credits = get("/alpha/billing/credits", apiKey: apiKey)
        async let subscription = get("/alpha/billing/subscriptions", apiKey: apiKey)
        return try Self.parse(credits: try await credits, subscription: try await subscription)
    }

    private func get(_ path: String, apiKey: String) async throws -> Data {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(path))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw FetchError.notSignedIn }
        guard status == 200 else { throw FetchError.http(path, status) }
        return data
    }

    static func parse(credits creditsData: Data, subscription subscriptionData: Data) throws -> CommandCodeUsage {
        struct Window: Decodable {
            let used: Double
            let cap: Double
            let resetAt: Double?
        }
        struct Credits: Decodable {
            struct Balance: Decodable {
                let monthlyCredits: Double?
                let purchasedCredits: Double?
                let freeCredits: Double?
            }
            struct Limits: Decodable {
                let limited: Bool?
                let fiveHour: Window?
                let weekly: Window?
            }
            let credits: Balance?
            let windowLimits: Limits?
        }
        struct Subscription: Decodable {
            struct Plan: Decodable {
                let status: String?
                let planId: String?
                let currentPeriodEnd: String?
                let cancelAtPeriodEnd: Bool?
                let cancelAt: String?
            }
            let data: Plan?
        }
        let credits = try JSONDecoder().decode(Credits.self, from: creditsData)
        let plan = try JSONDecoder().decode(Subscription.self, from: subscriptionData).data
        let parser = ISO8601Parser()

        let monthly = max(0, credits.credits?.monthlyCredits ?? 0)
        let extra = max(0, credits.credits?.purchasedCredits ?? 0) + max(0, credits.credits?.freeCredits ?? 0)
        let remaining = monthly + extra
        let planKey = plan?.planId.flatMap { id in
            planCredits.keys.sorted { $0.count > $1.count }.first { id.lowercased().replacingOccurrences(of: "_", with: "-").hasPrefix($0) }
        }
        let periodEnd = plan?.currentPeriodEnd.flatMap(parser.parse)

        var windows: [UsageWindow] = []
        // Same formula as the CLI's /usage: the pool is the plan's monthly credits (or what is left,
        // if larger) plus purchased and free credits.
        if plan?.status == "active", let planKey, let planMonthly = planCredits[planKey] {
            let pool = max(planMonthly, monthly) + extra
            windows.append(UsageWindow(
                id: "monthly", title: "Monthly credits",
                usedFraction: pool > 0 ? min(max((pool - remaining) / pool, 0), 1) : 0, resetsAt: periodEnd
            ))
        }
        if credits.windowLimits?.limited == true {
            for (id, title, window) in [("five_hour", "5 hours", credits.windowLimits?.fiveHour),
                                        ("weekly", "Weekly", credits.windowLimits?.weekly)] {
                guard let window, window.cap > 0 else { continue }
                // resetAt is epoch milliseconds, 0 while the window has not started.
                let resetsAt = window.resetAt.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
                windows.append(UsageWindow(id: id, title: title, usedFraction: min(window.used / window.cap, 1), resetsAt: resetsAt))
            }
        }
        return CommandCodeUsage(
            group: LimitGroup(id: "commandcode", title: "Command Code", windows: windows),
            planName: planKey.flatMap { planNames[$0] },
            creditsRemaining: remaining,
            periodEnd: periodEnd,
            endsAtPeriodEnd: plan?.cancelAtPeriodEnd == true || plan?.cancelAt != nil
        )
    }
}

/// A Command Code session (`~/.commandcode/projects/<project>/<id>.jsonl`).
public struct CommandCodeSession: Sendable, Identifiable {
    public let id: String
    public let title: String?
    public let projectPath: String
    public let lastActivity: Date
    /// Sum of the per-message `costUsd` Command Code records.
    public let cost: Double
    public let model: String?
}

public enum CommandCodeSessionReader {
    public static var projectsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".commandcode/projects")
    }

    public static func read(directory: URL = projectsDirectory, since cutoff: Date) -> [CommandCodeSession] {
        struct Line: Decodable {
            struct Usage: Decodable { let costUsd: Double? }
            let type: String?
            let id: String?
            let cwd: String?
            let timestamp: String?
            let usage: Usage?
            let model: String?
        }
        struct Meta: Decodable { let title: String? }
        let parser = ISO8601Parser()
        let decoder = JSONDecoder()

        return JSONLines.files(under: directory, suffix: ".jsonl", modifiedSince: cutoff)
            .filter { !$0.url.lastPathComponent.hasSuffix(".checkpoints.jsonl") }
            .compactMap { file -> CommandCodeSession? in
                var id: String?, cwd: String?, last: Date?
                var cost = 0.0
                var models: [String: Int] = [:]
                JSONLines.forEach(file.url) { data in
                    guard let line = try? decoder.decode(Line.self, from: data) else { return }
                    if line.type == "session" {
                        id = line.id
                        cwd = line.cwd
                    }
                    if let ts = line.timestamp.flatMap(parser.parse) { last = ts }
                    if let lineCost = line.usage?.costUsd { cost += lineCost }
                    if let model = line.model { models[model, default: 0] += 1 }
                }
                guard let id, let cwd else { return nil }
                let metaURL = file.url.deletingPathExtension().appendingPathExtension("meta.json")
                let title = (try? Data(contentsOf: metaURL)).flatMap { try? decoder.decode(Meta.self, from: $0) }?.title
                return CommandCodeSession(
                    id: id, title: title, projectPath: cwd, lastActivity: last ?? file.modified, cost: cost,
                    model: models.max { $0.value < $1.value }?.key
                )
            }
            .sorted { $0.lastActivity > $1.lastActivity }
    }
}
