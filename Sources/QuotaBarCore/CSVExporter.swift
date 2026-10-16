import Foundation

/// Writes the collected data as CSV files (UTF-8, comma separated, ISO 8601 timestamps).
public enum CSVExporter {
    public static func dailyCost(_ summary: CostSummary) -> String {
        let day = DateFormatter.isoDay
        var rows = [["date", "model", "input_tokens", "output_tokens", "cache_write_5m_tokens",
                     "cache_write_1h_tokens", "cache_read_tokens", "cost_usd"]]
        for item in summary.daily {
            rows.append([
                day.string(from: item.day), item.model,
                "\(item.tokens.input)", "\(item.tokens.output)", "\(item.tokens.cacheWrite5m)",
                "\(item.tokens.cacheWrite1h)", "\(item.tokens.cacheRead)", String(format: "%.4f", item.cost),
            ])
        }
        return render(rows)
    }

    public static func sessions(_ summary: CostSummary) -> String {
        let iso = ISO8601DateFormatter()
        var rows = [["session_id", "project_path", "title", "first_activity", "last_activity",
                     "total_tokens", "cost_usd", "models"]]
        for session in summary.sessions {
            rows.append([
                session.id, session.projectPath, session.title ?? "",
                iso.string(from: session.firstActivity), iso.string(from: session.lastActivity),
                "\(session.tokens.total)", String(format: "%.4f", session.cost), session.models.joined(separator: " "),
            ])
        }
        return render(rows)
    }

    public static func limitHistory(_ history: LimitHistory) -> String {
        let iso = ISO8601DateFormatter()
        var rows = [["timestamp", "provider", "series_id", "series", "used_percent"]]
        for sample in history.samples {
            rows.append([
                iso.string(from: sample.date), sample.provider, sample.seriesID, sample.seriesTitle,
                String(format: "%.1f", sample.usedFraction * 100),
            ])
        }
        return render(rows)
    }

    static func render(_ rows: [[String]]) -> String {
        rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

private extension DateFormatter {
    static var isoDay: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
