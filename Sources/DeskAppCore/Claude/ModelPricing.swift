import Foundation

public struct TokenCounts: Codable, Sendable, Equatable {
    public var input = 0
    public var output = 0
    public var cacheWrite5m = 0
    public var cacheWrite1h = 0
    public var cacheRead = 0

    public init(input: Int = 0, output: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0, cacheRead: Int = 0) {
        self.input = input
        self.output = output
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
    }

    public var total: Int { input + output + cacheWrite5m + cacheWrite1h + cacheRead }
    var promptTokens: Int { input + cacheWrite5m + cacheWrite1h + cacheRead }

    static func += (lhs: inout TokenCounts, rhs: TokenCounts) {
        lhs.input += rhs.input
        lhs.output += rhs.output
        lhs.cacheWrite5m += rhs.cacheWrite5m
        lhs.cacheWrite1h += rhs.cacheWrite1h
        lhs.cacheRead += rhs.cacheRead
    }
}

/// USD per million tokens. Cache writes are 1.25x (5 min) and 2x (1 hour) of input on every model;
/// the cache-read rate differs by model.
struct ModelPrice {
    let input: Double
    let output: Double
    let cacheRead: Double
    /// Some models switch to a second rate card when the prompt exceeds this many tokens.
    var longPromptThreshold: Int? = nil
    var longPromptMultiplier: Double = 1
}

public enum ModelPricing {
    // Anthropic first-party API rates, as of 2026-10.
    private static let table: [String: ModelPrice] = [
        "claude-fable-5-1": ModelPrice(input: 10, output: 50, cacheRead: 0.25),
        "claude-mythos-5-1": ModelPrice(input: 10, output: 50, cacheRead: 0.25),
        "claude-fable-5": ModelPrice(input: 10, output: 50, cacheRead: 1.0),
        "claude-opus-5-5": ModelPrice(input: 4, output: 20, cacheRead: 0.20),
        "claude-opus-5": ModelPrice(input: 5, output: 25, cacheRead: 0.50),
        "claude-opus-4-8": ModelPrice(input: 5, output: 25, cacheRead: 0.50),
        "claude-opus-4-7": ModelPrice(input: 5, output: 25, cacheRead: 0.50),
        "claude-opus-4-6": ModelPrice(input: 5, output: 25, cacheRead: 0.50),
        "claude-sonnet-5-5": ModelPrice(input: 2, output: 10, cacheRead: 0.20),
        "claude-sonnet-5": ModelPrice(input: 2, output: 10, cacheRead: 0.20),
        "claude-sonnet-4-6": ModelPrice(input: 3, output: 15, cacheRead: 0.30),
        "claude-haiku-5-5": ModelPrice(
            input: 0.10, output: 0.50, cacheRead: 0.01,
            longPromptThreshold: 100_000, longPromptMultiplier: 5
        ),
        "claude-haiku-4-5": ModelPrice(input: 1, output: 5, cacheRead: 0.10),
    ]

    /// Strips context-window tags (`[1m]`) and date snapshots (`-20250929`) from model ids.
    public static func normalize(_ model: String) -> String {
        var name = model.lowercased()
        if let bracket = name.firstIndex(of: "[") {
            name = String(name[..<bracket])
        }
        if let match = name.firstMatch(of: /^(.*)-\d{8}$/) {
            name = String(match.1)
        }
        return name
    }

    public static func isPriced(_ model: String) -> Bool {
        table[normalize(model)] != nil
    }

    /// Cost in USD of one request, or nil when the model is unknown.
    public static func cost(model: String, tokens: TokenCounts) -> Double? {
        guard let price = table[normalize(model)] else { return nil }
        var scale = 1.0 / 1_000_000
        if let threshold = price.longPromptThreshold, tokens.promptTokens > threshold {
            scale *= price.longPromptMultiplier
        }
        return (Double(tokens.input) * price.input
            + Double(tokens.cacheWrite5m) * price.input * 1.25
            + Double(tokens.cacheWrite1h) * price.input * 2
            + Double(tokens.cacheRead) * price.cacheRead
            + Double(tokens.output) * price.output) * scale
    }
}
