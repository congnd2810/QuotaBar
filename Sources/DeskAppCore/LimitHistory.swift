import Foundation

/// Rolling record of limit usage, kept for a fixed number of calendar days (today included).
/// Each day the window moves forward and samples from earlier days are dropped.
public struct LimitHistory: Codable, Sendable, Equatable {
    public struct Sample: Codable, Sendable, Equatable {
        public let date: Date
        public let provider: String
        /// Stable id, e.g. "claude/five_hour".
        public let seriesID: String
        /// Display name at the time of recording, e.g. "5 hours".
        public let seriesTitle: String
        public let usedFraction: Double
    }

    public static let defaultDays = 7

    public private(set) var samples: [Sample] = []

    public init() {}

    public mutating func record(provider: String, groups: [LimitGroup], at date: Date = Date()) {
        let multipleGroups = groups.count > 1
        for group in groups {
            for window in group.windows {
                samples.append(Sample(
                    date: date,
                    provider: provider,
                    seriesID: "\(provider)/\(group.id)/\(window.id)",
                    seriesTitle: multipleGroups ? "\(group.title) · \(window.title)" : window.title,
                    usedFraction: window.usedFraction
                ))
            }
        }
    }

    /// Drops samples older than the start of the oldest day in the window.
    public mutating func prune(now: Date = Date(), days: Int = defaultDays, calendar: Calendar = .current) {
        let cutoff = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now))!
        samples.removeAll { $0.date < cutoff }
    }

    public func samples(for provider: String) -> [Sample] {
        samples.filter { $0.provider == provider }
    }
}
