import Foundation

/// Cursor plan usage for the account signed in to the Cursor desktop app.
public struct CursorUsage: Sendable, Equatable {
    public let group: LimitGroup
    public let membership: String?
}

/// Uses the access token the Cursor app stores locally and the same dashboard endpoint cursor.com
/// uses (approach as in CodexBar). Never refreshes the token: when it expires, opening Cursor renews it.
public struct CursorFetcher: Sendable {
    public enum FetchError: LocalizedError {
        case notSignedIn
        case tokenExpired
        case http(Int)

        public var errorDescription: String? {
            switch self {
            case .notSignedIn: "Not signed in to the Cursor app."
            case .tokenExpired: "Cursor sign-in expired. Open Cursor to renew it."
            case .http(let code): "Cursor usage API error \(code)"
            }
        }
    }

    public static var stateDatabase: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    /// True when the Cursor app holds a sign-in token (not merely installed).
    public static var isSignedIn: Bool { (try? accessToken()) != nil }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch() async throws -> CursorUsage {
        guard let token = try Self.accessToken() else { throw FetchError.notSignedIn }
        guard let claims = Self.jwtClaims(token), let userID = claims.userID else { throw FetchError.notSignedIn }
        if let expiry = claims.expiry, expiry.timeIntervalSinceNow < 60 { throw FetchError.tokenExpired }

        var request = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!)
        request.setValue("WorkosCursorSessionToken=\(userID)%3A%3A\(token)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw FetchError.tokenExpired }
        guard status == 200 else { throw FetchError.http(status) }
        return try Self.parse(data)
    }

    static func accessToken(database: URL = stateDatabase) throws -> String? {
        guard FileManager.default.fileExists(atPath: database.path) else { return nil }
        let rows = try SQLiteReader(database)
            .rows("SELECT value FROM ItemTable WHERE key = ? LIMIT 1", ["cursorAuth/accessToken"])
        let token: String? = switch rows.first?["value"] {
        case let text as String: text
        // VS Code storage may keep values as UTF-16LE blobs.
        case let data as Data: String(data: data, encoding: .utf16LittleEndian) ?? String(data: data, encoding: .utf8)
        default: nil
        }
        return token.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `sub` is like `auth0|user_123`; the cookie wants the part after the last `|`.
    static func jwtClaims(_ token: String) -> (userID: String?, expiry: Date?)? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let userID = (json["sub"] as? String).flatMap { $0.split(separator: "|").last.map(String.init) }
        let expiry = (json["exp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return (userID, expiry)
    }

    static func parse(_ data: Data) throws -> CursorUsage {
        struct Bucket: Decodable {
            let enabled: Bool?
            let used: Double?
            let limit: Double?
            let totalPercentUsed: Double?
        }
        struct Summary: Decodable {
            struct Individual: Decodable {
                let plan: Bucket?
                let onDemand: Bucket?
            }
            let billingCycleEnd: String?
            let membershipType: String?
            let individualUsage: Individual?
        }
        let summary = try JSONDecoder().decode(Summary.self, from: data)
        let resetsAt = summary.billingCycleEnd.flatMap(ISO8601Parser().parse)
        var windows: [UsageWindow] = []
        if let plan = summary.individualUsage?.plan, plan.enabled != false {
            // totalPercentUsed is already a percentage (0.36 means 0.36%); amounts are cents.
            let fraction = plan.totalPercentUsed.map { $0 / 100 }
                ?? plan.used.flatMap { used in plan.limit.flatMap { $0 > 0 ? used / $0 : nil } }
            if let fraction {
                windows.append(UsageWindow(id: "plan", title: "Included usage",
                                           usedFraction: min(max(fraction, 0), 1), resetsAt: resetsAt))
            }
        }
        if let onDemand = summary.individualUsage?.onDemand, onDemand.enabled == true,
           let used = onDemand.used, let limit = onDemand.limit, limit > 0 {
            windows.append(UsageWindow(id: "on_demand", title: "On-demand",
                                       usedFraction: min(used / limit, 1), resetsAt: resetsAt))
        }
        return CursorUsage(group: LimitGroup(id: "cursor", title: "Cursor", windows: windows),
                           membership: summary.membershipType)
    }
}
