import Foundation
@testable import CodexBarCore

enum CostUsageControlledClockScanner {
    static func loadDailyReport(
        provider: UsageProvider,
        since: Date,
        until: Date,
        now: Date,
        options: CostUsageScanner.Options) -> CostUsageDailyReport
    {
        var options = options
        if options.codexScanBudgetForTesting == nil {
            // Count-based fixtures retain deadline mode without expiring under machine load.
            // Expiration tests supply their own clock-driven budget and keep that exact instance.
            let instant = ContinuousClock.now
            options.codexScanBudgetForTesting = CostUsageScanner.CodexScanBudget(
                maxFileBytes: options.maxCodexSessionFileBytes,
                maxBytesPerRefresh: options.maxCodexScanBytesPerRefresh,
                maxDuration: options.maxCodexScanDurationPerRefresh,
                now: { instant })
        }
        return CostUsageScanner.loadDailyReport(
            provider: provider, since: since, until: until, now: now, options: options)
    }
}
