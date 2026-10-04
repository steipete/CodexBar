import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageTemporalMergeMemoryTests {
    private static let start = Date(timeIntervalSince1970: 1_780_000_000)

    @Test(arguments: [0, 1, 2])
    func `empty supplements share the normalized slice buffer`(_ position: Int) {
        let slices = (0..<4096).map { index in
            CostUsageTimedEntry(
                timestamp: Self.start.addingTimeInterval(Double(index)),
                totalTokens: index.isMultiple(of: 3) ? nil : index,
                costUSD: index.isMultiple(of: 5) ? nil : Double(index) / 100,
                tokensAreComplete: index.isMultiple(of: 2),
                costIsComplete: index.isMultiple(of: 2))
        }
        let native = Self.report(slices)
        var reports = Array(repeating: Self.report([]), count: 3)
        reports[position] = native
        let inclusive = CostUsageDailyReport.merged(reports)

        Self.expectSameSlices(inclusive.quotaSlices, slices)
        #expect(Self.sharesBuffer(native.quotaSlices, inclusive.quotaSlices))
        // Native accounting and the inclusive result must retain one payload, not two.
        let retainedBuffers = Self.sharesBuffer(native.quotaSlices, inclusive.quotaSlices) ? 1 : 2
        #expect(retainedBuffers * slices.count * MemoryLayout<CostUsageTimedEntry>.stride == 163_840)
    }

    @Test
    func `nil invalid and incomplete metrics match the original accumulator`() {
        let tokens: [Int?] = [nil, -1, 0, 7, .max]
        let costs: [Double?] = [
            nil,
            -1,
            -0.0,
            0,
            0.1,
            .leastNonzeroMagnitude,
            .greatestFiniteMagnitude,
            .infinity,
            -.infinity,
            .nan,
        ]
        for token in tokens {
            for cost in costs {
                for completeTokens in [false, true] {
                    for completeCost in [false, true] {
                        let slices = [CostUsageTimedEntry(
                            timestamp: Self.start,
                            totalTokens: token,
                            costUSD: cost,
                            tokensAreComplete: completeTokens,
                            costIsComplete: completeCost)]
                        let merged = CostUsageDailyReport.merged([Self.report(slices), Self.report([])])
                        Self.expectSameSlices(merged.quotaSlices, Self.originalMerge([slices]))
                        if token.map({ $0 < 0 }) == true || cost.map({ !$0.isFinite || $0.sign == .minus }) == true {
                            #expect(!Self.sharesBuffer(slices, merged.quotaSlices))
                        }
                    }
                }
            }
        }
    }

    @Test
    func `duplicates unsorted input and multiple contributors retain aggregation semantics`() {
        let entries = [
            CostUsageTimedEntry(timestamp: Self.start, totalTokens: .max, costUSD: .greatestFiniteMagnitude),
            CostUsageTimedEntry(timestamp: Self.start, totalTokens: 1, costUSD: .greatestFiniteMagnitude),
            CostUsageTimedEntry(
                timestamp: Self.start.addingTimeInterval(1), totalTokens: nil, costUSD: 0.5),
            CostUsageTimedEntry(
                timestamp: Self.start.addingTimeInterval(2), totalTokens: 2, costUSD: nil),
        ]
        let fixtures: [[[CostUsageTimedEntry]]] = [
            [], [[]], [[], []],
            [entries, []],
            [Array(entries.reversed()), []],
            [[entries[3], entries[2]], []],
            [[entries[0]], [entries[1]]],
            [[entries[2]], [], [entries[3]]],
            [[], [entries[0], entries[2]], [entries[1], entries[3]]],
        ]
        for fixture in fixtures {
            let merged = CostUsageDailyReport.merged(fixture.map(Self.report))
            Self.expectSameSlices(merged.quotaSlices, Self.originalMerge(fixture))
        }
    }

    @Test
    func `slice reuse still merges daily summary coverage and hourly supplements`() {
        let day = CostUsageDailyReport.Entry(
            date: "2026-06-01",
            inputTokens: 2,
            outputTokens: 3,
            totalTokens: 5,
            costUSD: 0.1,
            modelsUsed: nil,
            modelBreakdowns: nil,
            pricedRequestCount: 1)
        let native = CostUsageDailyReport(
            data: [day],
            summary: nil,
            quotaSlices: [.init(timestamp: Self.start, totalTokens: 5, costUSD: 0.1)])
        let supplement = CostUsageDailyReport(
            data: [day],
            summary: nil,
            hourly: [.init(hour: Self.start, totalTokens: 7, costUSD: 0.2)])
        let merged = CostUsageDailyReport.merged([native, supplement])
        #expect(Self.sharesBuffer(native.quotaSlices, merged.quotaSlices))
        #expect(merged.data.first?.totalTokens == 10)
        #expect(merged.data.first?.pricedRequestCount == 2)
        #expect(merged.summary?.totalTokens == 10)
        #expect(merged.hourly.first?.totalTokens == 12)
    }

    private static func report(_ slices: [CostUsageTimedEntry]) -> CostUsageDailyReport {
        CostUsageDailyReport(data: [], summary: nil, quotaSlices: slices)
    }

    private static func sharesBuffer(_ lhs: [CostUsageTimedEntry], _ rhs: [CostUsageTimedEntry]) -> Bool {
        lhs.withUnsafeBufferPointer { left in
            rhs.withUnsafeBufferPointer { right in left.baseAddress == right.baseAddress }
        }
    }

    private static func expectSameSlices(_ actual: [CostUsageTimedEntry], _ expected: [CostUsageTimedEntry]) {
        #expect(actual == expected)
        // Equatable treats signed zero as equal; the accumulator's positive zero is observable.
        #expect(actual.map { $0.costUSD?.bitPattern } == expected.map { $0.costUSD?.bitPattern })
    }

    private static func originalMerge(_ sources: [[CostUsageTimedEntry]]) -> [CostUsageTimedEntry] {
        var buckets: [Date: CostUsageTemporalTotals] = [:]
        for slices in sources {
            for entry in slices {
                var accumulator = buckets[entry.timestamp] ?? CostUsageTemporalTotals()
                accumulator.add(
                    totalTokens: entry.totalTokens,
                    costUSD: entry.costUSD,
                    tokensAreComplete: entry.tokensAreComplete,
                    costIsComplete: entry.costIsComplete)
                buckets[entry.timestamp] = accumulator
            }
        }
        return buckets.keys.sorted().map { timestamp in
            buckets[timestamp, default: CostUsageTemporalTotals()].timedEntry(timestamp: timestamp)
        }
    }
}
