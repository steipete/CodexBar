import Foundation

extension CostUsageFetcher {
    static func loadMuseLocalSnapshot(
        environment: [String: String],
        now: Date,
        historyDays: Int,
        options: CostUsageScanner.Options) async throws -> CostUsageTokenSnapshot
    {
        let context = MuseLocalUsageReader.Context(environment: environment)
        let calendar = options.calendar
        let since = calendar.date(
            byAdding: .day, value: -(historyDays - 1), to: calendar.startOfDay(for: now)) ?? now
        let sinceKey = CostUsageLocalDay.key(from: since, calendar: calendar)
        let untilKey = CostUsageLocalDay.key(from: now, calendar: calendar)
        let cacheRoot = options.cacheRoot ?? context.defaultCacheRoot
        let result = try await CostUsageScanExecutor.run { cancellation in
            try MuseLocalUsageReader.makeDailyReportWithStatus(
                context: context,
                calendar: calendar,
                sinceDayKey: sinceKey,
                untilDayKey: untilKey,
                cacheRoot: cacheRoot,
                forceRescan: options.forceRescan,
                checkCancellation: cancellation)
        }
        return Self.tokenSnapshot(
            from: result.report,
            now: now,
            historyDays: historyDays,
            calendar: calendar,
            historyCoverageIsEstablished: result.isComplete && result.isAvailable,
            monetaryValuesAreAvailable: false)
    }
}
