import Foundation
import Testing
@testable import CodexBarCore

struct KimiK2UsageFetcherTests {
    @Test
    func `parses usage from nested usage`() throws {
        let json = """
        {
          "data": {
            "usage": {
              "total": 120,
              "credits_remaining": 30,
              "average_tokens": 42,
              "updated_at": "2024-01-02T03:04:05Z"
            }
          }
        }
        """

        let summary = try KimiK2UsageFetcher._parseSummaryForTesting(Data(json.utf8))
        let expectedDate = Date(timeIntervalSince1970: 1_704_164_645)

        #expect(summary.consumed == 120)
        #expect(summary.remaining == 30)
        #expect(summary.averageTokens == 42)
        #expect(abs(summary.updatedAt.timeIntervalSince1970 - expectedDate.timeIntervalSince1970) < 0.5)
    }

    @Test
    func `uses header fallback for remaining credits`() throws {
        let json = """
        { "total_credits_consumed": 50 }
        """
        let headers: [AnyHashable: Any] = ["X-Credits-Remaining": "25"]

        let summary = try KimiK2UsageFetcher._parseSummaryForTesting(Data(json.utf8), headers: headers)

        #expect(summary.consumed == 50)
        #expect(summary.remaining == 25)
    }

    @Test
    func `fetch ignores non-finite usage values`() async throws {
        let json = """
        {
          "total_credits_consumed": "NaN",
          "credits_remaining": "Infinity",
          "average_tokens": "1e309"
        }
        """
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["X-Credits-Remaining": "-Infinity"]))
            return (Data(json.utf8), response)
        }

        let snapshot = try await KimiK2UsageFetcher.fetchUsage(apiKey: "test-key", transport: transport)
        let summary = snapshot.summary

        #expect(summary.consumed == 0)
        #expect(summary.remaining == 0)
        #expect(summary.averageTokens == nil)
    }

    @Test
    func `parses numeric timestamp seconds`() throws {
        let json = """
        {
          "timestamp": 1700000000,
          "credits_remaining": 10,
          "total_credits_consumed": 5
        }
        """

        let summary = try KimiK2UsageFetcher._parseSummaryForTesting(Data(json.utf8))
        let expected = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(abs(summary.updatedAt.timeIntervalSince1970 - expected.timeIntervalSince1970) < 0.5)
    }

    @Test
    func `parses numeric timestamp milliseconds`() throws {
        let json = """
        {
          "timestamp": 1700000000000,
          "credits_remaining": 10,
          "total_credits_consumed": 5
        }
        """

        let summary = try KimiK2UsageFetcher._parseSummaryForTesting(Data(json.utf8))
        let expected = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(abs(summary.updatedAt.timeIntervalSince1970 - expected.timeIntervalSince1970) < 0.5)
    }

    @Test
    func `treats exact millisecond cutoff as milliseconds`() throws {
        let json = """
        {
          "timestamp": 1000000000000,
          "credits_remaining": 10,
          "total_credits_consumed": 5
        }
        """

        let summary = try KimiK2UsageFetcher._parseSummaryForTesting(Data(json.utf8))

        #expect(summary.updatedAt == Date(timeIntervalSince1970: 1_000_000_000))
    }

    @Test(arguments: ["NaN", "Infinity", "1e308", "0", "-1"])
    func `ignores invalid numeric timestamps`(timestamp: String) throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let json = """
        {
          "timestamp": "\(timestamp)",
          "credits_remaining": 10,
          "total_credits_consumed": 5
        }
        """

        let summary = try KimiK2UsageFetcher._parseSummaryForTesting(Data(json.utf8), now: now)

        #expect(summary.updatedAt == now)
    }

    @Test
    func `ignores timestamps beyond distant future`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let timestamp = Date.distantFuture.timeIntervalSince1970 + 1
        let json = """
        {
          "timestamp": "\(timestamp)",
          "credits_remaining": 10,
          "total_credits_consumed": 5
        }
        """

        let summary = try KimiK2UsageFetcher._parseSummaryForTesting(Data(json.utf8), now: now)

        #expect(summary.updatedAt == now)
    }

    @Test
    func `invalid root returns parse error`() {
        let json = """
        [{ "total": 1 }]
        """

        #expect {
            _ = try KimiK2UsageFetcher._parseSummaryForTesting(Data(json.utf8))
        } throws: { error in
            guard case let KimiK2UsageError.parseFailed(message) = error else { return false }
            return message == "Root JSON is not an object."
        }
    }

    @Test
    func `converts api key credits into text only snapshot`() {
        let usage = KimiK2UsageSummary(
            consumed: 10,
            remaining: 25,
            averageTokens: nil,
            updatedAt: Date()).toUsageSnapshot()

        #expect(usage.primary == nil)
        #expect(usage.identity?.providerID == .kimik2)
        #expect(usage.identity?.loginMethod == "Credits: 25 left")
    }
}
