import Foundation
import Testing
@testable import CodexBarCore

struct ProviderPluginCostUsageV2Tests {
    @Test(arguments: ProviderPluginTransportTests.engines)
    func `capability gated history preserves totals cache and unknown metrics`(
        engine: ProviderPluginEngineKind) async throws
    {
        let runtime = try ProviderPluginTransportTests.runtime(engine, body: """
        if (!ctx.env.supportsCostUsageV2) return { empty: true };
        return { costUsage: {
          version: 2, timeZone: 'Asia/Shanghai', windowStart: '2026-11-01', windowEnd: '2026-11-14',
          entries: [
            { date: '2026-11-13', totalTokens: '9007199254740993', inputTokens: '9007199254740992',
              outputTokens: 1, cacheReadTokens: 200, cacheCreationTokens: 0 },
            { date: '2026-11-14', totalTokens: 0, requests: null, cost: null }
          ]
        } };
        """)
        let snapshot = try #require(try await runtime.fetchUsage().costUsage)
        #expect(snapshot.dailyHistory?.timeZoneIdentifier == "Asia/Shanghai")
        #expect(snapshot.dailyHistory?.windowStart == "2026-11-01")
        #expect(snapshot.historyDays == 14)
        #expect(snapshot.daily.count == 2)
        #expect(snapshot.last30DaysTokens == 9_007_199_254_740_993)
        #expect(snapshot.daily[0].inputTokens == 9_007_199_254_740_992)
        #expect(snapshot.daily[0].cacheReadTokens == 200)
        #expect(snapshot.daily[0].cacheCreationTokens == 0)
        #expect(snapshot.last30DaysCostUSD == nil)
        #expect(snapshot.last30DaysRequests == nil)
        #expect(snapshot.daily[1].totalTokens == 0)
        #expect(snapshot.daily[1].inputTokens == nil)
        #expect(snapshot.currencyCode == "XXX")
    }

    @Test(arguments: ProviderPluginTransportTests.engines)
    func `version one cost usage remains compatible`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try ProviderPluginTransportTests.runtime(engine, body: """
        return { costUsage: { currency: 'USD', historyDays: 30, windowEnd: '2026-11-14', entries: [
          { date: '2026-11-14', inputTokens: 100, outputTokens: 20, requests: 0, cost: 0 }
        ] } };
        """)
        let snapshot = try #require(try await runtime.fetchUsage().costUsage)
        #expect(snapshot.last30DaysTokens == 120)
        #expect(snapshot.last30DaysCostUSD == 0)
        #expect(snapshot.last30DaysRequests == 0)
        #expect(snapshot.dailyHistory == nil)
    }

    @Test(arguments: ProviderPluginTransportTests.engines)
    func `invalid history rejects unsafe counts dates duplicates and overflow`(
        engine: ProviderPluginEngineKind) async throws
    {
        let rows = [
            "{ date: '2026-11-14', totalTokens: 9007199254740992 }",
            "{ date: '2026-11-14', totalTokens: -1 }",
            "{ date: '2026-11-14', totalTokens: 0.5 }",
            "{ date: '2026-11-14', totalTokens: '9223372036854775808' }",
            "{ date: '2026-11-14', totalTokens: '01' }",
            "{ date: '2026-11-14', totalTokens: true }",
            "{ date: '2026-11-14', cost: 1 }",
            "{ date: '2026-11-15', totalTokens: 1 }",
            "{ date: '2026-10-31', totalTokens: 1 }",
            "{ date: '2026-11-31', totalTokens: 1 }",
            "{ date: '2026-11-14', totalTokens: 1 }, { date: '2026-11-14', totalTokens: 1 }",
            "{ date: '2026-11-13', totalTokens: '9223372036854775807' }, { date: '2026-11-14', totalTokens: 1 }",
        ]
        for entries in rows {
            let runtime = try ProviderPluginTransportTests.runtime(engine, body: """
            return { costUsage: {
              version: 2, timeZone: 'Asia/Shanghai', windowStart: '2026-11-01', windowEnd: '2026-11-14',
              entries: [\(entries)]
            } };
            """)
            await #expect(throws: ProviderPluginError.self) { try await runtime.fetchUsage() }
        }
    }
}
