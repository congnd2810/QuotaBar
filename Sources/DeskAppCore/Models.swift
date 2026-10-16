import Foundation

/// One rate-limit window, e.g. "5 hours" or "weekly".
public struct UsageWindow: Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    /// 0...1, how much of the window has been consumed.
    public let usedFraction: Double
    public let resetsAt: Date?

    public init(id: String, title: String, usedFraction: Double, resetsAt: Date?) {
        self.id = id
        self.title = title
        self.usedFraction = usedFraction
        self.resetsAt = resetsAt
    }
}

/// A set of windows that share a quota (a provider, or a model group within a provider).
public struct LimitGroup: Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let windows: [UsageWindow]

    public init(id: String, title: String, windows: [UsageWindow]) {
        self.id = id
        self.title = title
        self.windows = windows
    }

    /// Fraction of the most constrained window in this group, or nil if there are no windows.
    public var maxUsedFraction: Double? {
        windows.map(\.usedFraction).max()
    }
}

/// ISO 8601 parser tolerant of fractional seconds of any precision (e.g. microseconds).
/// Not thread-safe; create one per owner.
final class ISO8601Parser {
    private let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func parse(_ string: String) -> Date? {
        if let date = withFraction.date(from: string) ?? plain.date(from: string) {
            return date
        }
        // Drop the fractional part, e.g. "…:59.521067+00:00" -> "…:59+00:00".
        guard let dot = string.firstIndex(of: ".") else { return nil }
        let rest = string[string.index(after: dot)...]
        let end = rest.firstIndex(where: { !$0.isNumber }) ?? rest.endIndex
        return plain.date(from: String(string[..<dot]) + String(rest[end...]))
    }
}
