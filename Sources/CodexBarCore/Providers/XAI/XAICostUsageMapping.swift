import Foundation

public enum XAICostUsageMapping {
    private static let dayPattern = #"^\d{4}-\d{2}-\d{2}$"#

    /// Maps the Management API daily-spend chart onto the shared spend catalog.
    /// Prepaid ledger balance is remaining credit, not spend, so it is never used here.
    public static func tokenSnapshot(from snapshot: UsageSnapshot, historyDays: Int) -> CostUsageTokenSnapshot? {
        let entries = snapshot.details
            .compactMap(\.chart)
            .flatMap(\.points)
            .compactMap { point -> CostUsageDailyReport.Entry? in
                guard point.label.range(of: self.dayPattern, options: .regularExpression) != nil,
                      point.value.isFinite,
                      point.value >= 0
                else { return nil }
                return CostUsageDailyReport.Entry(
                    date: point.label,
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: nil,
                    costUSD: point.value,
                    modelsUsed: nil,
                    modelBreakdowns: nil)
            }
            .sorted { $0.date < $1.date }
        guard !entries.isEmpty else { return nil }
        let total = entries.compactMap(\.costUSD).reduce(0, +)
        guard total.isFinite else { return nil }
        let latest = entries.last?.costUSD
        return CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: latest,
            last30DaysTokens: nil,
            last30DaysCostUSD: total,
            historyDays: historyDays,
            historyCoverageIsEstablished: snapshot.dataConfidence != .estimated,
            historyLabel: snapshot.dataConfidence == .estimated ? "Last 30 days (partial)" : nil,
            meteredCostUSD: total,
            costProvenance: .vendorMetered,
            daily: entries,
            updatedAt: snapshot.updatedAt)
    }
}
