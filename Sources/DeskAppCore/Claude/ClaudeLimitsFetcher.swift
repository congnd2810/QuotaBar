import Foundation

/// Fetches Pro/Max plan limits (5-hour and weekly windows) from the endpoint behind Claude Code's `/usage`.
/// The endpoint is internal and undocumented, so only the stable-looking fields are read.
public struct ClaudeLimitsFetcher: Sendable {
    public enum FetchError: LocalizedError {
        case http(Int, String)
        case refreshFailed(Int, String)
        case tokenExpired

        public var errorDescription: String? {
            switch self {
            case .http(429, _): "Claude is rate limiting requests (429). Will retry later."
            case .http(let code, let body): "Claude usage API error \(code): \(body)"
            case .refreshFailed(let code, let body): "Token refresh failed (\(code)): \(body). Open `claude` to sign in again."
            case .tokenExpired: "Claude sign-in token expired. Open `claude` to refresh it, or turn on automatic token refresh in Settings."
            }
        }
    }

    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    private let store: ClaudeCredentialStore
    private let session: URLSession

    public init(store: ClaudeCredentialStore = ClaudeCredentialStore(), session: URLSession = .shared) {
        self.store = store
        self.session = session
    }

    /// - Parameter allowRefresh: when false an expired token is reported instead of refreshed,
    ///   leaving the Keychain item to Claude Code alone.
    public func fetch(allowRefresh: Bool = true) async throws -> LimitGroup {
        var token = try await store.load()
        if token.isExpired() {
            guard allowRefresh else { throw FetchError.tokenExpired }
            token = try await refresh(token)
        }
        var (data, status) = try await requestUsage(token.accessToken)
        if status == 401 {
            // Claude Code may have rotated the token in the meantime; prefer its copy over refreshing again.
            let reloaded = try await store.load()
            if reloaded.accessToken != token.accessToken {
                token = reloaded
            } else {
                guard allowRefresh else { throw FetchError.tokenExpired }
                token = try await refresh(reloaded)
            }
            (data, status) = try await requestUsage(token.accessToken)
        }
        guard status == 200 else {
            throw FetchError.http(status, String(decoding: data.prefix(300), as: UTF8.self))
        }
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> LimitGroup {
        struct Window: Decodable {
            let utilization: Double?
            let resetsAt: String?
        }
        struct Response: Decodable {
            let fiveHour: Window?
            let sevenDay: Window?
            let sevenDayOpus: Window?
            let sevenDaySonnet: Window?
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(Response.self, from: data)
        let parser = ISO8601Parser()
        let candidates: [(String, String, Window?)] = [
            ("five_hour", "5 hours", response.fiveHour),
            ("seven_day", "7 days", response.sevenDay),
            ("seven_day_opus", "7 days · Opus", response.sevenDayOpus),
            ("seven_day_sonnet", "7 days · Sonnet", response.sevenDaySonnet),
        ]
        let windows = candidates.compactMap { id, title, window -> UsageWindow? in
            guard let window, let utilization = window.utilization else { return nil }
            return UsageWindow(
                id: id,
                title: title,
                usedFraction: utilization / 100,
                resetsAt: window.resetsAt.flatMap(parser.parse)
            )
        }
        return LimitGroup(id: "claude", title: "Claude", windows: windows)
    }

    private func requestUsage(_ accessToken: String) async throws -> (Data, Int) {
        var request = URLRequest(url: Self.usageURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("claude-cli/2.1.0 (external, cli)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Same request Claude Code makes. Refresh tokens rotate, so the new pair must be written back,
    /// otherwise Claude Code would be left holding a dead refresh token.
    private func refresh(_ token: ClaudeOAuthToken) async throws -> ClaudeOAuthToken {
        struct RefreshResponse: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresIn: Double
        }
        var body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": token.refreshToken,
            "client_id": Self.clientID,
        ]
        if !token.scopes.isEmpty {
            body["scope"] = token.scopes.joined(separator: " ")
        }
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw FetchError.refreshFailed(status, String(decoding: data.prefix(300), as: UTF8.self))
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let refreshed = try decoder.decode(RefreshResponse.self, from: data)
        let newToken = ClaudeOAuthToken(
            accessToken: refreshed.accessToken,
            refreshToken: refreshed.refreshToken ?? token.refreshToken,
            expiresAt: Date().addingTimeInterval(refreshed.expiresIn),
            scopes: token.scopes
        )
        try await store.update(
            accessToken: newToken.accessToken,
            refreshToken: newToken.refreshToken,
            expiresAt: newToken.expiresAt
        )
        return newToken
    }
}
