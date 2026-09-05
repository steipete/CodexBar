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

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: published.updatedAt)
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: today),
              let firstDay = Self.grokLocalDayKey(for: start, calendar: calendar),
              let lastDay = Self.grokLocalDayKey(for: today, calendar: calendar)
        else { return nil }
        let daily = published.daily.filter { $0.date >= firstDay && $0.date <= lastDay }
        guard !daily.isEmpty else { return nil }
        let tokens = daily.compactMap(\.totalTokens)
        let requests = daily.compactMap(\.requestCount)
        // Tokens and requests are recomputed from the retained days, so the cost has to be too. Copying the
        // published total would render the full 365-day amount beside a 30-day token count.
        let costs = daily.compactMap(\.costUSD)

        return CostUsageTokenSnapshot(
            sessionTokens: published.sessionTokens,
            sessionCostUSD: published.sessionCostUSD,
            sessionRequests: published.sessionRequests,
            last30DaysTokens: tokens.isEmpty ? nil : tokens.reduce(0, +),
            last30DaysCostUSD: costs.isEmpty ? nil : costs.reduce(0, +),
            last30DaysRequests: requests.isEmpty ? nil : requests.reduce(0, +),
            currencyCode: published.currencyCode,
            historyDays: days,
            historyCoverageIsEstablished: published.historyCoverageIsEstablished && published.historyDays >= days,
            historyLabel: published.historyLabel,
            meteredCostUSD: published.meteredCostUSD,
            costProvenance: GrokLocalSessionSummary.costProvenance(for: daily, fallback: published.costProvenance),
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
            lookbackDays: historyDays)
        return summary.toCostUsageTokenSnapshot(historyDays: historyDays)
    }

    /// Generic window math does not know that Grok's priced rows are CLI-recorded spend. Apply the same
    /// source-aware disclosure to live publications and scan results as to the remote-backed projection.
    func narrowedGrokTokenSnapshot(_ published: CostUsageTokenSnapshot, historyDays: Int) -> CostUsageTokenSnapshot {
        let narrowed = published.narrowed(
            toHistoryDays: historyDays,
            calendar: self.settings.costUsageBucketCalendar)
        return CostUsageTokenSnapshot(
            sessionTokens: narrowed.sessionTokens,
            sessionCostUSD: narrowed.sessionCostUSD,
            sessionRequests: narrowed.sessionRequests,
            last30DaysTokens: narrowed.last30DaysTokens,
            last30DaysCostUSD: narrowed.last30DaysCostUSD,
            last30DaysRequests: narrowed.last30DaysRequests,
            currencyCode: narrowed.currencyCode,
            historyDays: narrowed.historyDays,
            historyCoverageIsEstablished: narrowed.historyCoverageIsEstablished,
            historyLabel: narrowed.historyLabel,
            meteredCostUSD: narrowed.meteredCostUSD,
            costProvenance: GrokLocalSessionSummary.costProvenance(
                for: narrowed.daily,
                fallback: published.costProvenance),
            credentialScopeFingerprint: narrowed.credentialScopeFingerprint,
            daily: narrowed.daily,
            projects: narrowed.projects,
            sessions: narrowed.sessions,
            hourly: narrowed.hourly,
            updatedAt: narrowed.updatedAt)
    }

    private static func grokLocalDayKey(for date: Date, calendar: Calendar) -> String? {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
