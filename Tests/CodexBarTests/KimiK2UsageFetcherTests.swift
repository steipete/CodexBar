import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct KimiK2UsageFetcherTests {
    @Test
    func parsesUsageFromNestedUsage() throws {
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
    func usesHeaderFallbackForRemainingCredits() throws {
        let json = """
        { "total_credits_consumed": 50 }
        """
        let headers: [AnyHashable: Any] = ["X-Credits-Remaining": "25"]

        let summary = try KimiK2UsageFetcher._parseSummaryForTesting(Data(json.utf8), headers: headers)

        #expect(summary.consumed == 50)
        #expect(summary.remaining == 25)
    }

    @Test
    func parsesNumericTimestampSeconds() throws {
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
    func parsesNumericTimestampMilliseconds() throws {
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
    func invalidRootReturnsParseError() {
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
}
