import Foundation
import Testing
@testable import CodexBarCore

extension CostUsageStoreReadWorkTests {
    @Test(arguments: [1, 32])
    func `aggregate grouping visits rows independently of key count`(keyCount: Int) async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 128)
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.env.root.appendingPathComponent("aggregate-proof"))
        var cache = fixture.canonical
        cache.days = [:]
        for path in cache.files.keys.sorted() {
            var usage = try #require(cache.files[path])
            usage.days = [:]
            usage.codexCostNanos = nil
            usage.codexPrioritySurchargeNanos = nil
            usage.codexStandardCostNanos = nil
            usage.codexPriorityCostNanos = nil
            usage.codexStandardTokens = nil
            usage.codexPriorityTokens = nil
            usage.codexRows = (0..<128).map { index in
                Self.row(model: "fixture-model-\(index % keyCount)", event: index)
            }
            for index in 0..<keyCount {
                let model = "fixture-model-\(index)"
                usage.days[ReadWorkFixture.day, default: [:]][model] = [1280 / keyCount, 256 / keyCount, 384 / keyCount]
                cache.days[ReadWorkFixture.day, default: [:]][model] = [2560 / keyCount, 512 / keyCount, 768 / keyCount]
            }
            cache.files[path] = usage
        }
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: store.databaseURL)
        let previousRecorder = CostUsageStore.readWorkRecorderForTesting
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = previousRecorder }

        #expect(!Self.save(cache, store: store, fixture: fixture).catchUpRequired)
        let visits = recorder.snapshot().aggregateGroupingRowVisits
        print("[cost-aggregate-proof] rows=256 keys_per_file=\(keyCount) grouping_row_visits=\(visits)")
        #expect(visits > 0)
        #expect(visits <= 2 * fixture.rowCount)
        let aggregates = await store.fetchDayAggregates(sinceDay: ReadWorkFixture.day, untilDay: ReadWorkFixture.day)
        #expect(aggregates.count == keyCount)
        #expect(aggregates.allSatisfy { $0.requestCount == Int64(256 / keyCount) })
        #expect(aggregates.reduce(0) { $0 + $1.authoritativeCostNanos } == 256_000_000)

        var unchanged = store.syncLoadCodexCache(calendar: fixture.calendar)
        unchanged.lastScanUnixMs += 1000
        recorder.reset()
        #expect(!Self.save(unchanged, store: store, fixture: fixture).catchUpRequired)
        #expect(recorder.snapshot().aggregateGroupingRowVisits == 0)

        var other = fixture.canonical
        other.codexProjectMetadataVersion = (other.codexProjectMetadataVersion ?? 0) + 1
        #expect(!fixture.save(other).catchUpRequired)
        #expect(recorder.snapshot().aggregateGroupingRowVisits == 0)
    }

    @Test
    func `aggregate persistence preserves packed totals row pricing and key boundaries`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.env.root.appendingPathComponent("aggregate-parity"))
        var cache = fixture.canonical
        let day = ReadWorkFixture.day
        let model = ReadWorkFixture.model
        for path in cache.files.keys.sorted() {
            var usage = try #require(cache.files[path])
            usage.days = [day: [model: [101, 17, 23], "packed-only": [5]]]
            usage.codexCostNanos = [day: ["cost-only": 11]]
            usage.codexPrioritySurchargeNanos = [day: ["surcharge-only": 12]]
            usage.codexStandardCostNanos = [day: ["standard-cost-only": 13]]
            usage.codexPriorityCostNanos = [day: ["priority-cost-only": 14]]
            usage.codexStandardTokens = [day: ["standard-tokens-only": 15]]
            usage.codexPriorityTokens = [day: ["priority-tokens-only": 16]]
            usage.codexRows = [
                Self.row(event: 0, input: 10, cached: 2, output: 3, reasoning: 1, cost: 0),
                Self.row(event: 1, input: 20, cached: 4, output: 5, cost: nil, mode: nil),
                Self.row(event: 2, input: 30, cached: 6, output: 7, reasoning: 2, cost: 7, mode: "priority"),
                Self.row(event: 3, input: 40, cached: 8, output: 9, reasoning: 3, cost: nil, mode: "priority"),
                Self.row(
                    day: "2026-08-02",
                    model: model,
                    event: 4,
                    input: -3,
                    cached: -2,
                    output: 5,
                    reasoning: 0,
                    cost: nil,
                    mode: "other"),
            ]
            cache.files[path] = usage
        }
        cache.days = [day: [model: [401, 41, 53], "global-only": [7, 2, 1]]]
        #expect(!Self.save(cache, store: store, fixture: fixture).catchUpRequired)

        var main = CostUsageStoreDayAggregate.zero(day: day, model: model)
        main.inputTokens = 101
        main.cachedTokens = 17
        main.outputTokens = 23
        main.reasoningTokens = 6
        main.requestCount = 4
        main.authoritativeCostNanos = 7
        main.standardInputTokens = 20
        main.standardCachedTokens = 4
        main.standardOutputTokens = 5
        main.priorityInputTokens = 40
        main.priorityCachedTokens = 8
        main.priorityOutputTokens = 9
        main.standardTokens = 38
        main.priorityTokens = 86
        var packedOnly = CostUsageStoreDayAggregate.zero(day: day, model: "packed-only")
        packedOnly.inputTokens = 5
        var rowOnly = CostUsageStoreDayAggregate.zero(day: "2026-08-02", model: model)
        rowOnly.requestCount = 1
        rowOnly.standardInputTokens = -3
        rowOnly.standardCachedTokens = -2
        rowOnly.standardOutputTokens = 5
        rowOnly.standardTokens = 5
        let metadataOnly = [
            "cost-only",
            "surcharge-only",
            "standard-cost-only",
            "priority-cost-only",
            "standard-tokens-only",
            "priority-tokens-only",
        ]
            .map { CostUsageStoreDayAggregate.zero(day: day, model: $0) }
        let expectedFiles = (metadataOnly + [main, packedOnly, rowOnly])
            .sorted { ($0.day, $0.model) < ($1.day, $1.model) }

        var global = main
        global.inputTokens = 401
        global.cachedTokens = 41
        global.outputTokens = 53
        global.reasoningTokens = 12
        global.requestCount = 8
        global.authoritativeCostNanos = 14
        global.standardInputTokens = 40
        global.standardCachedTokens = 8
        global.standardOutputTokens = 10
        global.priorityInputTokens = 80
        global.priorityCachedTokens = 16
        global.priorityOutputTokens = 18
        global.standardTokens = 76
        global.priorityTokens = 172
        var globalOnly = CostUsageStoreDayAggregate.zero(day: day, model: "global-only")
        globalOnly.inputTokens = 7
        globalOnly.cachedTokens = 2
        globalOnly.outputTokens = 1
        let expectedGlobals = [global, globalOnly].sorted { ($0.day, $0.model) < ($1.day, $1.model) }

        for metadataRefresh in [false, true] {
            if metadataRefresh {
                cache.codexProjectMetadataVersion = (cache.codexProjectMetadataVersion ?? 0) + 1
                #expect(!Self.save(cache, store: store, fixture: fixture).catchUpRequired)
            }
            for path in cache.files.keys.sorted() {
                #expect(await store.fetchFileDayAggregates(path: path) == expectedFiles)
            }
            #expect(await store.fetchDayAggregates(sinceDay: day, untilDay: "2026-08-02") == expectedGlobals)
        }
    }

    private static func save(
        _ cache: CostUsageCache,
        store: CostUsageStore,
        fixture: ReadWorkFixture) -> CostUsageStoreBudgetResult
    {
        store.syncSaveCodexCache(
            cache,
            calendar: fixture.calendar,
            requestedScanWindow: (sinceKey: "2026-08-01", untilKey: "2026-08-02"),
            skipIdenticalContent: true)
    }

    private static func row(
        day: String = ReadWorkFixture.day,
        model: String = ReadWorkFixture.model,
        event: Int,
        input: Int = 10,
        cached: Int = 2,
        output: Int = 3,
        reasoning: Int? = nil,
        cost: Int64? = 1_000_000,
        mode: String? = "standard") -> CostUsageScanner.CodexUsageRow
    {
        .init(
            day: day,
            model: model,
            turnID: "fixture-\(event)",
            eventIndex: event,
            input: input,
            cached: cached,
            output: output,
            reasoning: reasoning,
            knownCostNanos: cost,
            pricingModel: model,
            pricingMode: mode)
    }
}
