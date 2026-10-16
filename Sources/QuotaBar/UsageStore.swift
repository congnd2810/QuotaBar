import QuotaBarCore
import Foundation
import Observation

enum Provider {
    static let claude = "claude"
    static let antigravity = "antigravity"
    static let commandCode = "commandcode"
    static let cursor = "cursor"
}

@MainActor
@Observable
final class UsageStore {
    private(set) var claudeLimits: LimitGroup?
    private(set) var claudeLimitsError: String?
    private(set) var antigravityGroups: [LimitGroup] = []
    private(set) var antigravityError: String?
    private(set) var cost: CostSummary?
    private(set) var costError: String?
    private(set) var lastUpdated: Date?
    private(set) var isRefreshing = false
    /// Limit usage over the last 7 days, persisted across launches.
    private(set) var history: LimitHistory
    /// Top-level `agy` conversations of the last 30 days.
    private(set) var agySessions: [AgySession] = []
    private(set) var codexLimits: CodexLimits?
    private(set) var codexSessions: [CodexSession] = []
    private(set) var commandCode: CommandCodeUsage?
    private(set) var commandCodeError: String?
    private(set) var commandCodeSessions: [CommandCodeSession] = []
    private(set) var cursor: CursorUsage?
    private(set) var cursorError: String?
    /// OpenCode has no plan limits; only its sessions are shown.
    private(set) var openCodeSessions: [OpenCodeSession] = []

    private let limitsFetcher = ClaudeLimitsFetcher()
    private let antigravityFetcher = AntigravityQuotaFetcher()
    private let scanner: ClaudeCodeUsageScanner
    private let settings: AppSettings
    private var pollTask: Task<Void, Never>?

    private static let supportDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("QuotaBar")
    private static let historyURL = supportDirectory.appendingPathComponent("limit-history.json")

    init(settings: AppSettings) {
        self.settings = settings
        scanner = ClaudeCodeUsageScanner(cacheURL: Self.supportDirectory.appendingPathComponent("claude-code-usage.json"))
        history = (try? Data(contentsOf: Self.historyURL))
            .flatMap { try? JSONDecoder().decode(LimitHistory.self, from: $0) } ?? LimitHistory()
        restartPollingOnSettingsChange()
    }

    /// Menu bar widgets show the most constrained window of each quota pool.
    var claudeWidget: MenuBarWidget {
        MenuBarWidget(caption: "CLAUDE", fraction: claudeLimits?.maxUsedFraction)
    }

    var antigravityWidgets: [MenuBarWidget] {
        let fractions = AntigravityQuotaFetcher.summaryFractions(for: antigravityGroups)
        return [
            MenuBarWidget(caption: "AG GEMINI", fraction: fractions.gemini),
            MenuBarWidget(caption: "AG CLAUDE·GPT", fraction: fractions.external),
        ]
    }

    var codexWidget: MenuBarWidget {
        MenuBarWidget(caption: "CODEX", fraction: codexLimits?.current().group.maxUsedFraction)
    }

    var commandCodeWidget: MenuBarWidget {
        MenuBarWidget(caption: "CMD", fraction: commandCode?.group.maxUsedFraction)
    }

    var cursorWidget: MenuBarWidget {
        MenuBarWidget(caption: "CURSOR", fraction: cursor?.group.maxUsedFraction)
    }

    /// Extra context lines shown under a provider's limits.
    var codexNotes: [String] {
        guard let limits = codexLimits else {
            return ["No plan limits in Codex logs yet. Codex records them only when signed in with a ChatGPT plan."]
        }
        let plan = limits.planType.map { "\($0.capitalized) plan · " } ?? ""
        return [plan + "From Codex logs, recorded \(limits.recordedAt.formatted(date: .abbreviated, time: .shortened)). Windows past their reset show 0%."]
    }

    var commandCodeNotes: [String] {
        guard let usage = commandCode else { return [] }
        var line = (usage.planName.map { "\($0) plan · " } ?? "")
            + "\(usage.creditsRemaining.formatted(.currency(code: "USD"))) credits left"
        if let end = usage.periodEnd {
            let date = end.formatted(date: .abbreviated, time: .omitted)
            line += usage.endsAtPeriodEnd ? " · Cancelled, ends \(date)" : " · Renews \(date)"
        }
        return [line]
    }

    var cursorNotes: [String] {
        cursor?.membership.map { ["\($0.capitalized) plan"] } ?? []
    }

    nonisolated static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "–" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        enum Update: Sendable {
            case limits(Result<LimitGroup, any Error>)
            case antigravity(Result<[LimitGroup], any Error>)
            case cost(Result<CostSummary, any Error>)
            case agySessions(Result<[AgySession], any Error>)
            case codex(CodexLimits?, [CodexSession])
            case commandCode(Result<CommandCodeUsage, any Error>)
            case commandCodeSessions([CommandCodeSession])
            case cursor(Result<CursorUsage, any Error>)
            case openCodeSessions([OpenCodeSession])
        }
        let cutoff = Calendar.current.date(byAdding: .day, value: -29, to: Calendar.current.startOfDay(for: Date()))!
        let limitsFetcher = limitsFetcher, antigravityFetcher = antigravityFetcher, scanner = scanner
        let allowTokenRefresh = settings.autoRefreshClaudeToken
        await withTaskGroup(of: Update.self) { group in
            // Hidden providers are not fetched (agy in particular is slow).
            if settings.showClaude {
                group.addTask { .limits(await capture { try await limitsFetcher.fetch(allowRefresh: allowTokenRefresh) }) }
                group.addTask { .cost(await capture { await scanner.scan() }) }
            }
            if settings.showAntigravity {
                group.addTask { .antigravity(await capture { try await antigravityFetcher.fetch() }) }
                group.addTask { .agySessions(await capture { try AgySessionReader.read(since: cutoff) }) }
            }
            if settings.showCodex {
                group.addTask { .codex(CodexReader.latestLimits(), CodexReader.sessions(since: cutoff)) }
            }
            if settings.showCommandCode {
                group.addTask { .commandCode(await capture { try await CommandCodeFetcher().fetch() }) }
                group.addTask { .commandCodeSessions(CommandCodeSessionReader.read(since: cutoff)) }
            }
            if settings.showCursor {
                group.addTask { .cursor(await capture { try await CursorFetcher().fetch() }) }
            }
            if OpenCodeReader.isInstalled {
                group.addTask { .openCodeSessions((try? OpenCodeReader.sessions(since: cutoff)) ?? []) }
            }

            // Apply each source as soon as it finishes; agy alone can take several seconds.
            // On failure keep the previous values so the popover shows the last known numbers.
            for await update in group {
                switch update {
                case .limits(.success(let value)):
                    claudeLimits = value; claudeLimitsError = nil
                    history.record(provider: Provider.claude, groups: [value])
                case .limits(.failure(let error)): claudeLimitsError = error.localizedDescription
                case .antigravity(.success(let value)):
                    antigravityGroups = value; antigravityError = nil
                    history.record(provider: Provider.antigravity, groups: value)
                case .antigravity(.failure(let error)): antigravityError = error.localizedDescription
                case .cost(.success(let value)): cost = value; costError = nil
                case .cost(.failure(let error)): costError = error.localizedDescription
                case .agySessions(.success(let value)): agySessions = value
                case .agySessions(.failure): break // keep the last list; agy may be writing its index
                case .codex(let limits, let sessions):
                    codexLimits = limits; codexSessions = sessions
                case .commandCode(.success(let value)):
                    commandCode = value; commandCodeError = nil
                    history.record(provider: Provider.commandCode, groups: [value.group])
                case .commandCode(.failure(let error)): commandCodeError = error.localizedDescription
                case .commandCodeSessions(let value): commandCodeSessions = value
                case .cursor(.success(let value)):
                    cursor = value; cursorError = nil
                    history.record(provider: Provider.cursor, groups: [value.group])
                case .cursor(.failure(let error)): cursorError = error.localizedDescription
                case .openCodeSessions(let value): openCodeSessions = value
                }
            }
        }
        lastUpdated = Date()
        history.prune()
        saveHistory()
    }

    private func saveHistory() {
        do {
            try FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(history).write(to: Self.historyURL, options: .atomic)
        } catch {
            // History is best effort; the next refresh tries again.
        }
    }

    /// (Re)starts the poll loop now and whenever a setting it depends on changes,
    /// so a new interval or a newly shown provider applies immediately.
    private func restartPollingOnSettingsChange() {
        pollTask?.cancel()
        let interval = withObservationTracking {
            _ = (settings.showClaude, settings.showAntigravity, settings.showCodex, settings.showCommandCode,
                 settings.showCursor, settings.autoRefreshClaudeToken)
            return Duration.seconds(settings.refreshMinutes * 60)
        } onChange: { [weak self] in
            Task { @MainActor in self?.restartPollingOnSettingsChange() }
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }
}

private func capture<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> Result<T, any Error> {
    do {
        return .success(try await operation())
    } catch {
        return .failure(error)
    }
}
