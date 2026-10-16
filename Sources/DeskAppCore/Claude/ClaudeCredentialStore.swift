import Foundation

public struct ClaudeOAuthToken: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public let scopes: [String]

    public func isExpired(now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        expiresAt.timeIntervalSince(now) < leeway
    }
}

/// Reads and writes the Keychain item Claude Code stores its OAuth credentials in.
///
/// Goes through `/usr/bin/security` rather than the Security framework: the item was created by
/// that tool, so it is already on the item's access list and macOS does not prompt.
public struct ClaudeCredentialStore: Sendable {
    public enum CredentialError: LocalizedError {
        case notFound
        case missingOAuth
        case writeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notFound: "Claude Code credentials not found in Keychain. Sign in with `claude`."
            case .missingOAuth: "Credentials have no claudeAiOauth section. Run `claude` and sign in again."
            case .writeFailed(let message): "Could not save the new token to Keychain: \(message)"
            }
        }
    }

    public let service: String
    private let security = "/usr/bin/security"

    public init(service: String = "Claude Code-credentials") {
        self.service = service
    }

    public func load() async throws -> ClaudeOAuthToken {
        try Self.token(from: try await readJSON())
    }

    /// Stores refreshed tokens, keeping every other field of the item (e.g. MCP OAuth entries) untouched.
    public func update(accessToken: String, refreshToken: String, expiresAt: Date) async throws {
        var json = try await readJSON()
        var oauth = json["claudeAiOauth"] as? [String: Any] ?? [:]
        oauth["accessToken"] = accessToken
        oauth["refreshToken"] = refreshToken
        oauth["expiresAt"] = Int64(expiresAt.timeIntervalSince1970 * 1000)
        json["claudeAiOauth"] = oauth

        let payload = try JSONSerialization.data(withJSONObject: json)
        let hex = payload.map { String(format: "%02x", $0) }.joined()
        let result = try await ProcessRunner.run(
            security, ["add-generic-password", "-U", "-a", try await readAccount(), "-s", service, "-X", hex]
        )
        guard result.status == 0 else {
            throw CredentialError.writeFailed(String(decoding: result.stderr, as: UTF8.self))
        }
    }

    static func token(from json: [String: Any]) throws -> ClaudeOAuthToken {
        guard let oauth = json["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String,
              let refresh = oauth["refreshToken"] as? String,
              let expiresAt = (oauth["expiresAt"] as? NSNumber)?.doubleValue
        else { throw CredentialError.missingOAuth }
        return ClaudeOAuthToken(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date(timeIntervalSince1970: expiresAt / 1000),
            scopes: oauth["scopes"] as? [String] ?? []
        )
    }

    private func readJSON() async throws -> [String: Any] {
        let result = try await ProcessRunner.run(security, ["find-generic-password", "-s", service, "-w"])
        guard result.status == 0 else { throw CredentialError.notFound }
        var data = result.stdout
        while data.last == UInt8(ascii: "\n") { data.removeLast() }
        // `security -w` prints the value as hex when it contains non-printable bytes.
        if data.first != UInt8(ascii: "{"), let decoded = Data(hexString: String(decoding: data, as: UTF8.self)) {
            data = decoded
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CredentialError.missingOAuth
        }
        return json
    }

    private func readAccount() async throws -> String {
        let result = try await ProcessRunner.run(security, ["find-generic-password", "-s", service])
        let text = String(decoding: result.stdout, as: UTF8.self)
        guard let match = text.firstMatch(of: /"acct"<blob>="([^"]*)"/) else { throw CredentialError.notFound }
        return String(match.1)
    }
}

extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
