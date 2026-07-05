import Foundation
import Testing
@testable import CodexBarCore

struct DeepSeekAccountSummaryParserTests {
    private func data(_ json: String) -> Data {
        Data(json.utf8)
    }

    @Test
    func `parses normal and bonus wallets`() throws {
        let json = """
        {
          "code": 0,
          "data": { "biz_code": 0, "biz_data": {
            "current_token": 10000000,
            "normal_wallets": [{ "currency": "CNY", "balance": "27.6241338", "token_estimation": "9208044" }],
            "bonus_wallets":  [{ "currency": "CNY", "balance": "0", "token_estimation": "0" }],
            "total_available_token_estimation": "9208044",
            "monthly_costs":  [{ "currency": "CNY", "amount": "0" }],
            "monthly_token_usage": "0"
          }}
        }
        """
        let summary = try DeepSeekUsageFetcher._parseAccountSummaryForTesting(self.data(json))
        #expect(summary.currency == "CNY")
        #expect(abs(summary.paidBalance - 27.6241338) < 0.0001)
        #expect(summary.grantedBalance == 0)
        #expect(abs(summary.totalBalance - 27.6241338) < 0.0001)
        #expect(summary.availableTokenEstimation == 9_208_044)
        #expect(summary.monthlyCost == 0)
        #expect(summary.monthlyTokenUsage == 0)
    }

    @Test
    func `parses string monthly token usage`() throws {
        let json = """
        {
          "code": 0,
          "data": { "biz_code": 0, "biz_data": {
            "normal_wallets": [{ "currency": "CNY", "balance": "27.15", "token_estimation": "9052464" }],
            "bonus_wallets": [],
            "total_available_token_estimation": "9052464",
            "monthly_token_usage": "901408"
          }}
        }
        """
        let summary = try DeepSeekUsageFetcher._parseAccountSummaryForTesting(self.data(json))
        #expect(summary.availableTokenEstimation == 9_052_464)
        #expect(summary.monthlyTokenUsage == 901_408)
    }

    @Test
    func `prefers USD wallet when funded`() throws {
        let json = """
        {
          "code": 0,
          "data": { "biz_code": 0, "biz_data": {
            "normal_wallets": [
              { "currency": "CNY", "balance": "10", "token_estimation": "100" },
              { "currency": "USD", "balance": "5", "token_estimation": "50" }
            ],
            "bonus_wallets": [{ "currency": "USD", "balance": "1", "token_estimation": "10" }],
            "total_available_token_estimation": "60"
          }}
        }
        """
        let summary = try DeepSeekUsageFetcher._parseAccountSummaryForTesting(self.data(json))
        #expect(summary.currency == "USD")
        #expect(summary.paidBalance == 5)
        #expect(summary.grantedBalance == 1)
    }

    @Test
    func `prefers funded wallet when USD row is empty`() throws {
        let json = """
        {
          "code": 0,
          "data": { "biz_code": 0, "biz_data": {
            "normal_wallets": [
              { "currency": "USD", "balance": "0", "token_estimation": "0" },
              { "currency": "CNY", "balance": "27.15", "token_estimation": "9052464" }
            ],
            "bonus_wallets": []
          }}
        }
        """
        let summary = try DeepSeekUsageFetcher._parseAccountSummaryForTesting(self.data(json))
        #expect(summary.currency == "CNY")
        #expect(abs(summary.paidBalance - 27.15) < 0.0001)
    }

    @Test
    func `auth failure code maps to invalid credentials`() {
        let json = #"{ "code": 40003, "msg": "authorization failed" }"#
        #expect(throws: DeepSeekUsageError.self) {
            _ = try DeepSeekUsageFetcher._parseAccountSummaryForTesting(data(json))
        }
    }

    @Test
    func `empty wallets throw parse failed`() {
        let json = """
        { "code": 0, "data": { "biz_code": 0, "biz_data": { "normal_wallets": [], "bonus_wallets": [] } } }
        """
        #expect(throws: DeepSeekUsageError.self) {
            _ = try DeepSeekUsageFetcher._parseAccountSummaryForTesting(data(json))
        }
    }
}
