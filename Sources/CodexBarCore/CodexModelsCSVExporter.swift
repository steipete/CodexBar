import Foundation

public enum CodexModelsCSVExporter {
    private static let columns = [
        "query_scope",
        "period_start",
        "period_end",
        "canonical_model_id",
        "display_name",
        "raw_aliases",
        "associated_session_ids",
        "active_metric",
        "tokens",
        "input_tokens",
        "cached_input_tokens",
        "output_tokens",
        "reasoning_tokens",
        "share",
        "session_references",
        "previous_tokens",
        "previous_session_references",
        "known_cost",
        "previous_known_cost",
        "cost_status",
        "cost_coverage",
        "previous_cost_status",
        "previous_cost_coverage",
        "currency",
        "priced_tokens",
        "unpriced_tokens",
        "previous_priced_tokens",
        "previous_unpriced_tokens",
        "comparison_kind",
        "comparison_value",
        "index_revision",
        "snapshot_generated_at",
    ]

    public static func export(
        snapshot: CodexModelsAnalyticsSnapshot,
        rows: [CodexModelsRow]? = nil,
        metric: CodexModelsMetric = .tokens) -> String
    {
        let iso8601 = ISO8601DateFormatter()
        let rows = rows ?? snapshot.rows
        let body = rows.map { row in
            let comparison = self.comparisonFields(row.comparison(metric))
            let share = String(format: "%.17g", snapshot.share(of: row, metric: metric))
            let associatedSessionIDs = (row.associatedSessionIDs ?? []).joined(separator: "|")
            let previousTokens = row.previousTotalTokens.map(String.init) ?? ""
            let previousSessionReferences = row.previousSessionReferences.map(String.init) ?? ""
            let knownCost = row.cost.pricedTokens == 0
                ? ""
                : NSDecimalNumber(decimal: row.cost.knownAmount).stringValue
            let previousKnownCost = row.previousCost.flatMap { cost in
                cost.pricedTokens == 0 ? nil : NSDecimalNumber(decimal: cost.knownAmount).stringValue
            } ?? ""
            let costStatus = self.costStatus(row.cost, usageTokens: row.totalTokens)
            let previousCostStatus = row.previousCost.map {
                self.costStatus($0, usageTokens: $0.pricedTokens + $0.unpricedTokens)
            } ?? "unavailable"
            let fields: [String] = [
                snapshot.scopeID ?? "all_workspaces",
                iso8601.string(from: snapshot.currentInterval.start),
                iso8601.string(from: snapshot.currentInterval.end),
                row.id,
                row.displayName,
                row.rawAliases.joined(separator: "|"),
                associatedSessionIDs,
                metric.rawValue,
                String(row.totalTokens),
                String(row.inputTokens),
                String(row.cachedInputTokens),
                String(row.outputTokens),
                row.reasoningTokens.map(String.init) ?? "",
                share,
                String(row.sessionReferences),
                previousTokens,
                previousSessionReferences,
                knownCost,
                previousKnownCost,
                costStatus,
                String(format: "%.17g", row.cost.coverage),
                previousCostStatus,
                row.previousCost.map { String(format: "%.17g", $0.coverage) } ?? "",
                row.cost.currencyCode,
                String(row.cost.pricedTokens),
                String(row.cost.unpricedTokens),
                row.previousCost.map { String($0.pricedTokens) } ?? "",
                row.previousCost.map { String($0.unpricedTokens) } ?? "",
                comparison.kind,
                comparison.value,
                snapshot.indexRevision,
                iso8601.string(from: snapshot.generatedAt),
            ]
            return fields.map(self.escape).joined(separator: ",")
        }
        return ([self.columns.joined(separator: ",")] + body).joined(separator: "\n") + "\n"
    }

    private static func comparisonFields(_ comparison: CodexModelsComparison) -> (kind: String, value: String) {
        switch comparison {
        case .unavailable: ("unavailable", "")
        case .new: ("new", "")
        case .ended: ("ended", "")
        case .unchanged: ("unchanged", "0")
        case let .percent(value): ("percent", String(format: "%.17g", value))
        }
    }

    private static func costStatus(_ cost: CodexModelsCost, usageTokens: Int64) -> String {
        if usageTokens == 0 { return "no_usage" }
        if cost.pricedTokens == 0 { return "unavailable" }
        if cost.unpricedTokens > 0 { return "partial" }
        return "known"
    }

    private static func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
