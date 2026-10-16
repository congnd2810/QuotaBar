import AppKit
import Charts
import QuotaBarCore
import SwiftUI

struct ClaudePopover: View {
    let store: UsageStore
    let openSettings: () -> Void
    let openSessions: () -> Void

    var body: some View {
        PopoverChrome(title: "Claude", brand: .claude, store: store, openSettings: openSettings) {
            LimitSection(
                title: "Plan limits",
                groups: store.claudeLimits.map { [$0] } ?? [],
                error: store.claudeLimitsError,
                isLoading: store.isRefreshing
            )
            HistorySection(samples: store.history.samples(for: Provider.claude))
            CostSection(summary: store.cost, error: store.costError)
            Button {
                openSessions()
            } label: {
                Label("Sessions by project", systemImage: "list.bullet.rectangle")
            }
        }
    }
}

struct AntigravityPopover: View {
    let store: UsageStore
    let openSettings: () -> Void

    var body: some View {
        PopoverChrome(title: "Antigravity", brand: .antigravity, store: store, openSettings: openSettings) {
            LimitSection(
                title: "Quota",
                groups: store.antigravityGroups,
                error: store.antigravityError,
                isLoading: store.isRefreshing
            )
            HistorySection(samples: store.history.samples(for: Provider.antigravity))
        }
    }
}

/// Providers shown with the generic popover.
enum LimitProvider {
    case codex, commandCode, cursor

    var brand: ProviderBrand {
        switch self {
        case .codex: .codex
        case .commandCode: .commandCode
        case .cursor: .cursor
        }
    }

    var title: String { brand.name }
}

/// Popover for providers that only report plan limits (Codex, Command Code, Cursor).
/// Reads the store in `body` so it updates as data arrives.
struct ProviderPopover: View {
    let provider: LimitProvider
    let store: UsageStore
    let openSettings: () -> Void
    let openSessions: () -> Void

    private var groups: [LimitGroup] {
        switch provider {
        case .codex: store.codexLimits.map { [$0.current().group] } ?? []
        case .commandCode: store.commandCode.map { [$0.group] } ?? []
        case .cursor: store.cursor.map { [$0.group] } ?? []
        }
    }

    private var error: String? {
        switch provider {
        case .codex: nil
        case .commandCode: store.commandCodeError
        case .cursor: store.cursorError
        }
    }

    private var notes: [String] {
        switch provider {
        case .codex: store.codexNotes
        case .commandCode: store.commandCodeNotes
        case .cursor: store.cursorNotes
        }
    }

    /// Codex numbers are log snapshots, not live readings, so they are kept out of the history.
    private var historyProvider: String? {
        switch provider {
        case .codex: nil
        case .commandCode: Provider.commandCode
        case .cursor: Provider.cursor
        }
    }

    var body: some View {
        PopoverChrome(title: provider.title, brand: provider.brand, store: store, openSettings: openSettings) {
            LimitSection(title: "Plan limits", groups: groups, error: error, isLoading: store.isRefreshing)
            ForEach(notes, id: \.self) { note in
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let historyProvider {
                HistorySection(samples: store.history.samples(for: historyProvider))
            }
            Button {
                openSessions()
            } label: {
                Label("Sessions by project", systemImage: "list.bullet.rectangle")
            }
        }
    }
}

/// Header (title, last update, refresh) and footer (settings, quit) shared by every provider popover.
private struct PopoverChrome<Content: View>: View {
    let title: String
    var brand: ProviderBrand?
    let store: UsageStore
    let openSettings: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            content
            Divider()
            HStack {
                Button {
                    openSettings()
                } label: {
                    Label("Settings…", systemImage: "gearshape")
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private var header: some View {
        HStack {
            if let brand {
                ProviderLogo(brand: brand, size: 20)
            }
            Text(title).font(.headline)
            Spacer()
            if let lastUpdated = store.lastUpdated {
                Text("Updated \(lastUpdated.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await store.refresh() }
            } label: {
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(store.isRefreshing)
        }
    }
}

private struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

private struct ErrorText: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct LimitSection: View {
    let title: String
    let groups: [LimitGroup]
    let error: String?
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: title)
            ForEach(groups) { group in
                if groups.count > 1 {
                    Text(group.title).font(.subheadline.weight(.medium))
                }
                ForEach(group.windows) { window in
                    LimitRow(window: window)
                }
            }
            if groups.isEmpty && error == nil && isLoading {
                ProgressView().controlSize(.small)
            }
            if let error {
                ErrorText(message: error)
            }
        }
    }
}

private struct LimitRow: View {
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.title)
                Spacer()
                Text("\(UsageStore.percent(window.usedFraction)) used")
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            .font(.callout)
            ProgressView(value: min(max(window.usedFraction, 0), 1))
                .tint(tint)
            if let resetsAt = window.resetsAt {
                Text("Resets \(resetsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())) · in \(resetsAt, style: .relative)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var tint: Color {
        switch window.usedFraction {
        case ..<0.7: .green
        case ..<0.9: .orange
        default: .red
        }
    }
}

/// % used per limit window over the rolling 7-day history.
private struct HistorySection: View {
    let samples: [LimitHistory.Sample]

    /// Label every series with its latest recorded title.
    private var titles: [String: String] {
        Dictionary(samples.map { ($0.seriesID, $0.seriesTitle) }) { _, latest in latest }
    }

    /// A line needs two points; until some series has them there is nothing to draw.
    private var hasLine: Bool {
        Dictionary(grouping: samples, by: \.seriesID).values.contains { $0.count > 1 }
    }

    var body: some View {
        if hasLine {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: "Last 7 days")
                // Several series share a timestamp, so samples are identified by position.
                Chart(Array(samples.enumerated()), id: \.offset) { _, sample in
                    LineMark(
                        x: .value("Time", sample.date),
                        y: .value("Used", sample.usedFraction * 100)
                    )
                    .foregroundStyle(by: .value("Limit", titles[sample.seriesID] ?? sample.seriesTitle))
                    .interpolationMethod(.stepEnd)
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(values: [0, 50, 100]) { value in
                        AxisGridLine()
                        AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%") }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) {
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                    }
                }
                .chartLegend(position: .bottom, alignment: .leading)
                .chartPlotStyle { plotArea in
                    plotArea.frame(height: 90)
                }
            }
        }
    }
}

private struct CostSection: View {
    static let chartDays = 14

    let summary: CostSummary?
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Claude Code · API-equivalent cost")
            if let summary {
                HStack(spacing: 0) {
                    stat("Today", summary.cost(since: daysAgo(0)))
                    stat("7 days", summary.cost(since: daysAgo(6)))
                    stat("30 days", summary.cost(since: daysAgo(29)))
                }
                chart(summary)
                if !summary.unpricedModels.isEmpty {
                    Text("No price for: \(summary.unpricedModels.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if error == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Scanning Claude Code logs…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error {
                ErrorText(message: error)
            }
        }
    }

    private func stat(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value, format: .currency(code: "USD").precision(.fractionLength(2)))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chart(_ summary: CostSummary) -> some View {
        let start = daysAgo(Self.chartDays - 1)
        return Chart(summary.daily.filter { $0.day >= start }) { item in
            BarMark(
                x: .value("Day", item.day, unit: .day),
                y: .value("USD", item.cost)
            )
            .foregroundStyle(by: .value("Model", item.model))
        }
        .chartXScale(domain: start...Calendar.current.date(byAdding: .day, value: 1, to: daysAgo(0))!)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 2)) {
                AxisValueLabel(format: .dateTime.day().month(.defaultDigits))
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(amount, format: .currency(code: "USD").precision(.fractionLength(0)))
                    }
                }
            }
        }
        .chartLegend(position: .bottom, alignment: .leading)
        .chartPlotStyle { plotArea in
            plotArea.frame(height: 110)
        }
    }

    private func daysAgo(_ days: Int) -> Date {
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: Date()))!
    }
}
