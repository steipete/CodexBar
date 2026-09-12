import Foundation

public enum XAICostUsageMapping {
    public static let historyDays = 30
    private static let dayPattern = #"^\d{4}-\d{2}-\d{2}$"#

    /// True when prepaid balance arrived but `/usage` history did not.
    public static func isAnalyticsUnavailable(_ snapshot: UsageSnapshot) -> Bool {
        !snapshot.details.contains { $0.chart != nil }
    }

    /// Maps the Management API daily-spend chart onto the shared spend catalog.
    /// Prepaid ledger balance is remaining credit, not spend, so it is never used here.
    public static func tokenSnapshot(from snapshot: UsageSnapshot, historyDays _: Int) -> CostUsageTokenSnapshot? {
        guard let chart = snapshot.details.compactMap(\.chart).first else { return nil }
        let entries = chart.points
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
        let total = entries.compactMap(\.costUSD).reduce(0, +)
        guard total.isFinite else { return nil }
        let today = self.utcDayKey(snapshot.updatedAt)
        return CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: entries.first { $0.date == today }?.costUSD,
            last30DaysTokens: nil,
            last30DaysCostUSD: total,
            historyDays: Self.historyDays,
            historyCoverageIsEstablished: snapshot.dataConfidence != .estimated,
            historyLabel: snapshot.dataConfidence == .estimated ? "Last 30 days (partial)" : nil,
            meteredCostUSD: total,
            costProvenance: .vendorMetered,
            daily: entries,
            updatedAt: snapshot.updatedAt)
    }

    static func utcDayKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0)
    }
}
