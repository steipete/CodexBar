import CodexBarCore
import Foundation

extension UsageStore {
    func grokLocalTokenSnapshot(
        from providerSnapshot: UsageSnapshot?,
        historyDays: Int) -> CostUsageTokenSnapshot?
    {
        let published = providerSnapshot?.costUsage ?? (providerSnapshot == nil ? self.tokenSnapshots[.grok] : nil)
        guard let published else { return nil }
        let days = max(1, historyDays)
        guard published.historyDays != days else { return published }

        let calendar = self.settings.costUsageBucketCalendar
        let today = calendar.startOfDay(for: published.updatedAt)
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: today),
              let firstDay = Self.grokLocalDayKey(for: start, calendar: calendar),
              let lastDay = Self.grokLocalDayKey(for: today, calendar: calendar)
        else { return nil }
        let daily = published.daily.filter { $0.date >= firstDay && $0.date <= lastDay }
        guard !daily.isEmpty || !published.historyCoverageIsEstablished else { return nil }
        let tokens = daily.compactMap(\.totalTokens)
        let requests = daily.compactMap(\.requestCount)

        return CostUsageTokenSnapshot(
            sessionTokens: published.sessionTokens,
            sessionCostUSD: published.sessionCostUSD,
            sessionRequests: published.sessionRequests,
            last30DaysTokens: tokens.isEmpty ? nil : tokens.reduce(0, +),
            last30DaysCostUSD: published.last30DaysCostUSD,
            last30DaysRequests: requests.isEmpty ? nil : requests.reduce(0, +),
            currencyCode: published.currencyCode,
            historyDays: days,
            historyCoverageIsEstablished: published.historyCoverageIsEstablished && published.historyDays >= days,
            historyLabel: published.historyLabel,
            meteredCostUSD: published.meteredCostUSD,
            costProvenance: published.costProvenance,
            credentialScopeFingerprint: published.credentialScopeFingerprint,
            daily: daily,
            projects: published.projects,
            sessions: published.sessions,
            hourly: published.hourly,
            updatedAt: published.updatedAt)
    }

    func loadGrokLocalTokenSnapshot(historyDays: Int) async throws -> CostUsageTokenSnapshot? {
        let summary = try await GrokLocalSessionScanner.summarizeOffMainThread(
            env: self.environmentBase,
            lookbackDays: historyDays,
            calendar: self.settings.costUsageBucketCalendar)
        return summary.toCostUsageTokenSnapshot(
            historyDays: historyDays,
            calendar: self.settings.costUsageBucketCalendar)
    }

    private static func grokLocalDayKey(for date: Date, calendar: Calendar) -> String? {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
