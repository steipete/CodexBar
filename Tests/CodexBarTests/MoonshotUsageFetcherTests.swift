import Foundation
import Testing
@testable import CodexBarCore

struct MoonshotUsageFetcherTests {
    @Test
    func `parses documented response`() throws {
        let json = """
        {
          "code": 0,
          "data": {
            "available_balance": 49.58,
            "voucher_balance": 50.00,
            "cash_balance": 12.34
          },
          "scode": "0x0",
          "status": true
        }
        """

        let summary = try MoonshotUsageFetcher._parseSummaryForTesting(Data(json.utf8))

        #expect(summary.availableBalance == 49.58)
        #expect(summary.voucherBalance == 50.00)
        #expect(summary.cashBalance == 12.34)

        let usage = MoonshotUsageSnapshot(summary: summary).toUsageSnapshot()
        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(usage.loginMethod(for: .moonshot) == "Balance: $49.58")
    }

    @Test
    func `negative cash balance is surfaced as deficit`() throws {
        let json = """
        {
          "code": 0,
          "data": {
            "available_balance": 49.58,
            "voucher_balance": 50.00,
            "cash_balance": -0.42
          },
          "scode": "0x0",
          "status": true
        }
        """

        let summary = try MoonshotUsageFetcher._parseSummaryForTesting(Data(json.utf8))
        let usage = MoonshotUsageSnapshot(summary: summary).toUsageSnapshot()

        #expect(summary.cashBalance == -0.42)
        #expect(usage.loginMethod(for: .moonshot)?.contains("in deficit") == true)
    }

    @Test
    func `invalid root returns parse error`() {
        let json = """
        [{ "available_balance": 1 }]
        """

        #expect {
            _ = try MoonshotUsageFetcher._parseSummaryForTesting(Data(json.utf8))
        } throws: { error in
            guard case let MoonshotUsageError.parseFailed(message) = error else { return false }
            return message == "Root JSON is not an object."
        }
    }

    @Test
    func `international host uses moonshot ai`() {
        let url = MoonshotUsageFetcher.resolveBalanceURL(region: .international)

        #expect(url.absoluteString == "https://api.moonshot.ai/v1/users/me/balance")
    }

    @Test
    func `china host uses moonshot cn`() {
        let url = MoonshotUsageFetcher.resolveBalanceURL(region: .china)

        #expect(url.absoluteString == "https://api.moonshot.cn/v1/users/me/balance")
    }
}
