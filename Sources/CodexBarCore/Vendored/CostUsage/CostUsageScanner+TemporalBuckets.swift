import Foundation

extension CostUsageScanner {
    struct HourlyBucket {
        var totalTokens = 0
        var sawTokens = false
        var tokensAreComplete = true
        var costUSD = 0.0
        var sawCost = false
        var costIsComplete = true

        mutating func addTokens(_ tokens: Int) {
            guard tokens >= 0 else {
                self.tokensAreComplete = false
                return
            }
            let (sum, overflowed) = self.totalTokens.addingReportingOverflow(tokens)
            if overflowed {
                self.tokensAreComplete = false
            } else {
                self.totalTokens = sum
                self.sawTokens = true
            }
        }

        mutating func addCost(_ costUSD: Double) {
            guard costUSD.isFinite, costUSD >= 0 else {
                self.costIsComplete = false
                return
            }
            let sum = self.costUSD + costUSD
            if sum.isFinite {
                self.costUSD = sum
                self.sawCost = true
            } else {
                self.costIsComplete = false
            }
        }

        mutating func add(tokens: Int, costUSD: Double?) {
            self.addTokens(tokens)
            if let costUSD {
                self.addCost(costUSD)
            }
        }

        func entry(hour: Date) -> CostUsageHourlyEntry {
            CostUsageHourlyEntry(
                hour: hour,
                totalTokens: self.sawTokens && self.tokensAreComplete ? self.totalTokens : nil,
                costUSD: self.sawCost && self.costIsComplete ? self.costUSD : nil)
        }

        func timedEntry(timestamp: Date) -> CostUsageTimedEntry {
            CostUsageTimedEntry(
                timestamp: timestamp,
                totalTokens: self.sawTokens && self.tokensAreComplete ? self.totalTokens : nil,
                costUSD: self.sawCost && self.costIsComplete ? self.costUSD : nil)
        }
    }

    struct TemporalBuckets {
        var hourly: [Date: HourlyBucket] = [:]
        var quotaSlices: [Date: HourlyBucket] = [:]
    }

    static func hourStart(for timestamp: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .hour, for: timestamp)?.start ?? timestamp
    }

    static func date(fromUnixMs millis: Int64?) -> Date? {
        millis.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    static func sortedHourlyEntries(_ buckets: [Date: HourlyBucket]) -> [CostUsageHourlyEntry] {
        buckets.keys.sorted().map { hour in
            (buckets[hour] ?? HourlyBucket()).entry(hour: hour)
        }
    }

    static func sortedQuotaSlices(_ buckets: [Date: HourlyBucket]) -> [CostUsageTimedEntry] {
        buckets.keys.sorted().map { timestamp in
            (buckets[timestamp] ?? HourlyBucket()).timedEntry(timestamp: timestamp)
        }
    }

    private struct CodexHourlyShare {
        let timestamp: Date?
        let tokens: Int
        let resolvedCostUSD: Double?
    }

    static func addCodexHourly(
        rows: [CodexUsageRow],
        billedCostUSD: Double?,
        pricing: CodexReportDayPricingContext,
        calendar: Calendar,
        into buckets: inout TemporalBuckets)
    {
        let shares = rows.map { row -> CodexHourlyShare in
            let tokens = max(0, row.input) + max(0, row.output)
            let resolvedCost = self.codexResolvedCostUSD(
                for: row,
                priorityTurns: pricing.priorityTurns,
                modelsDevCatalog: pricing.modelsDevCatalog,
                modelsDevCacheRoot: pricing.modelsDevCacheRoot,
                customPricing: pricing.customPricing)
            return CodexHourlyShare(
                timestamp: self.date(fromUnixMs: row.timestampUnixMs),
                tokens: tokens,
                resolvedCostUSD: resolvedCost.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
        }
        let allocations = self.codexRowCostAllocations(shares: shares, billedCostUSD: billedCostUSD)

        for index in shares.indices {
            let share = shares[index]
            guard let timestamp = share.timestamp else { continue }
            let hour = self.hourStart(for: timestamp, calendar: calendar)
            var hourly = buckets.hourly[hour] ?? HourlyBucket()
            var timed = buckets.quotaSlices[timestamp] ?? HourlyBucket()
            hourly.add(tokens: share.tokens, costUSD: allocations[index])
            timed.add(tokens: share.tokens, costUSD: allocations[index])
            buckets.hourly[hour] = hourly
            buckets.quotaSlices[timestamp] = timed
        }
    }

    private static func codexRowCostAllocations(
        shares: [CodexHourlyShare],
        billedCostUSD: Double?) -> [Double?]
    {
        var allocations = shares.map(\.resolvedCostUSD)
        guard let billedCostUSD, billedCostUSD.isFinite, billedCostUSD >= 0, !shares.isEmpty else {
            return allocations
        }
        guard allocations.allSatisfy({ $0 != nil }) else {
            // An unresolved row can carry an arbitrary share of the remainder. Preserve only the
            // independently resolved rows and let daily reconciliation model the rest coarsely.
            return allocations
        }
        let knownTotal = allocations.compactMap(\.self).reduce(0, +)
        guard knownTotal.isFinite else { return Array(repeating: nil, count: shares.count) }
        let tolerance = max(1e-9, billedCostUSD * 1e-9)
        let correction = billedCostUSD - knownTotal
        guard abs(correction) <= tolerance else {
            // A material remainder represents missing aggregate coverage, not cost that can be
            // assigned to a known event timestamp.
            return allocations
        }
        guard let correctionTarget = allocations.indices.max(by: {
            (allocations[$0] ?? 0) < (allocations[$1] ?? 0)
        }), let current = allocations[correctionTarget], current + correction >= 0
        else { return Array(repeating: nil, count: shares.count) }
        allocations[correctionTarget] = current + correction
        guard allocations.allSatisfy({ value in
            value.map { $0.isFinite && $0 >= 0 } ?? false
        }) else { return Array(repeating: nil, count: shares.count) }
        return allocations
    }
}
