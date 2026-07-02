import Foundation
import Testing
@testable import CodexBarCore

struct MiniMaxUsageSummaryTests {
    @Test
    func `parses usage summary with cache hit percentages`() throws {
        let body = """
        {
          "total_days": 77,
          "total_token_consumed": "2.37B",
          "active_days": 60,
          "current_consecutive_days": 31,
          "last_update_time": "07-02 17:00",
          "daily_token_usage": [201889, 2800317, 4486224],
          "date_model_usage": [
            {
              "date": "2026-06-29",
              "models": [
                {
                  "model": "MiniMax-M3-512k",
                  "input_token": 200395,
                  "cache_read_token": 172249,
                  "cache_create_token": 0,
                  "output_token": 1494,
                  "total_token": 374138,
                  "cache_hit_percent": "85.95%"
                }
              ],
              "total_input_token": 200395,
              "total_cache_read_token": 172249,
              "total_cache_create_token": 0,
              "total_output_token": 1494,
              "total_token": 201889,
              "cache_hit_percent": "85.95%"
            },
            {
              "date": "2026-06-30",
              "models": [],
              "total_input_token": 2778091,
              "total_cache_read_token": 1809827,
              "total_cache_create_token": 0,
              "total_output_token": 22226,
              "total_token": 2800317,
              "cache_hit_percent": "65.15%"
            },
            {
              "date": "2026-07-01",
              "models": [],
              "total_input_token": 4454050,
              "total_cache_read_token": 3139433,
              "total_cache_create_token": 0,
              "total_output_token": 32174,
              "total_token": 4486224,
              "cache_hit_percent": "70.48%"
            }
          ],
          "base_resp": { "status_code": 0, "status_msg": "success" }
        }
        """

        let summary = try MiniMaxUsageSummaryParser.parse(data: Data(body.utf8))

        #expect(summary.totalTokenConsumed == "2.37B")
        #expect(summary.activeDays == 60)
        #expect(summary.currentConsecutiveDays == 31)
        #expect(summary.lastUpdateTime == "07-02 17:00")
        #expect(summary.days.count == 3)
        #expect(summary.days[0].cacheHitPercent == 85.95)
        #expect(summary.days[0].models[0].cacheHitPercent == 85.95)
        #expect(summary.last30DaysTokens == 7_488_430)
        #expect(summary.last7DaysTokens == 7_488_430)
        #expect(summary.latestSnapshotTokens == 4_486_224)
        #expect(summary.hasDisplayableData)
        #expect(summary.latestActiveDay?.date == "2026-07-01")
    }

    @Test
    func `snapshot tokens prefer update day over previous full day`() {
        let summary = MiniMaxUsageSummary(
            totalDays: 2,
            totalTokenConsumed: "1.0M",
            usageRankingPercent: nil,
            activeDays: 2,
            currentConsecutiveDays: 2,
            lastUpdateTime: "07-02 20:00",
            dailyTokenUsage: [4_486_224, 88000],
            days: [
                MiniMaxUsageSummaryDay(
                    date: "2026-07-01",
                    totalInputToken: 4_000_000,
                    totalCacheReadToken: 3_000_000,
                    totalCacheCreateToken: 0,
                    totalOutputToken: 32000,
                    totalToken: 4_486_224,
                    cacheHitPercent: 70.48,
                    models: []),
                MiniMaxUsageSummaryDay(
                    date: "2026-07-02",
                    totalInputToken: 86000,
                    totalCacheReadToken: 64000,
                    totalCacheCreateToken: 0,
                    totalOutputToken: 2500,
                    totalToken: 88000,
                    cacheHitPercent: 74.63,
                    models: []),
            ])

        #expect(summary.latestSnapshotTokens == 88000)
        #expect(summary.snapshotDay?.date == "2026-07-02")
    }

    @Test
    func `synthesizes trend days from daily token usage when model usage is missing`() {
        let summary = MiniMaxUsageSummary(
            totalDays: 3,
            totalTokenConsumed: "1.0M",
            usageRankingPercent: nil,
            activeDays: 3,
            currentConsecutiveDays: 3,
            lastUpdateTime: "07-02 18:00",
            dailyTokenUsage: [100, 200, 300],
            days: [])

        #expect(summary.hasDisplayableData)
        let trend = summary.trendDays(last: 3)
        #expect(trend.map(\.date) == ["2026-06-30", "2026-07-01", "2026-07-02"])
        #expect(trend.map(\.totalToken) == [100, 200, 300])
        #expect(summary.last7DaysTokens == 600)
        #expect(summary.latestSnapshotTokens == 300)
    }
}
