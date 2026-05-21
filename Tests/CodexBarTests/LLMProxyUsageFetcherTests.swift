import CodexBarCore
import Foundation
import Testing

struct LLMProxyUsageFetcherTests {
    @Test
    func `parses quota stats summary`() throws {
        let json = """
        {
          "providers": {
            "openai": {
              "credential_count": 3,
              "active_count": 2,
              "exhausted_count": 1,
              "total_requests": 120,
              "tokens": {
                "input_cached": 1000,
                "input_uncached": 2000,
                "output": 3000
              },
              "approx_cost": 12.5,
              "quota_groups": {
                "default": {
                  "remaining_percent": 42,
                  "reset_time": "2026-05-18T12:00:00Z"
                }
              }
            },
            "anthropic": {
              "credential_count": 1,
              "active_count": 1,
              "exhausted_count": 0,
              "total_requests": 40,
              "tokens": {
                "input_cached": 0,
                "input_uncached": 500,
                "output": 500
              },
              "approx_cost": 3.0,
              "quota_groups": [
                { "remaining_percent": 80 }
              ]
            }
          },
          "summary": {
            "total_requests": 160,
            "total_tokens": 7000,
            "approx_cost": 15.5
          }
        }
        """

        let parsed = try LLMProxyUsageFetcher._parseSnapshotForTesting(
            Data(json.utf8),
            updatedAt: Date(timeIntervalSince1970: 1))

        #expect(parsed.providerCount == 2)
        #expect(parsed.credentialCount == 4)
        #expect(parsed.activeCredentialCount == 3)
        #expect(parsed.exhaustedCredentialCount == 1)
        #expect(parsed.totalRequests == 160)
        #expect(parsed.totalTokens == 7000)
        #expect(parsed.approximateCostUSD == 15.5)
        #expect(parsed.minimumRemainingPercent == 42)

        let snapshot = parsed.toUsageSnapshot()
        #expect(snapshot.identity?.providerID == .llmproxy)
        #expect(snapshot.primary?.usedPercent == 58)
        #expect(snapshot.secondary?.resetDescription == "160 requests")
        #expect(snapshot.tertiary?.resetDescription == "7,000 tokens")
        #expect(snapshot.providerCost?.used == 15.5)
    }

    @Test
    func `quota stats url accepts versioned or root base urls`() throws {
        #expect(
            try LLMProxyUsageFetcher
                ._quotaStatsURLForTesting(baseURL: #require(URL(string: "https://proxy.example.com")))
                .absoluteString == "https://proxy.example.com/v1/quota-stats")
        #expect(
            try LLMProxyUsageFetcher
                ._quotaStatsURLForTesting(baseURL: #require(URL(string: "https://proxy.example.com/v1")))
                .absoluteString == "https://proxy.example.com/v1/quota-stats")
    }

    @Test
    func `parses fractional second quota reset times`() throws {
        let json = """
        {
          "providers": {
            "openai": {
              "quota_groups": [
                {
                  "remaining_percent": 42,
                  "reset_time": "2026-05-18T12:00:00.123Z"
                }
              ]
            }
          }
        }
        """

        let parsed = try LLMProxyUsageFetcher._parseSnapshotForTesting(
            Data(json.utf8),
            updatedAt: Date(timeIntervalSince1970: 1))
        let components = DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 5,
            day: 18,
            hour: 12,
            minute: 0,
            second: 0,
            nanosecond: 123_000_000)
        let expected = try #require(components.date)

        #expect(try abs(#require(parsed.nextResetAt).timeIntervalSince(expected)) < 0.001)
    }
}
