import Foundation
import Testing
@testable import CodexBarCore

struct KimiK2BalanceParsingTests {
    @Test
    func `parses standard balance response`() throws {
        let json = """
        {
          "data": {
            "available_balance": 100.00,
            "voucher_balance": 10.00,
            "cash_balance": 90.00
          }
        }
        """
        let info = try KimiK2UsageFetcher._parseBalanceForTesting(Data(json.utf8))
        #expect(info != nil)
        #expect(info?.availableBalance == 100.00)
        #expect(info?.voucherBalance == 10.00)
        #expect(info?.cashBalance == 90.00)
    }

    @Test
    func `parses camelCase balance response`() throws {
        let json = """
        {
          "data": {
            "availableBalance": 50.0,
            "voucherBalance": 5.0,
            "cashBalance": 45.0
          }
        }
        """
        let info = try KimiK2UsageFetcher._parseBalanceForTesting(Data(json.utf8))
        #expect(info?.availableBalance == 50.0)
        #expect(info?.voucherBalance == 5.0)
        #expect(info?.cashBalance == 45.0)
    }

    @Test
    func `falls back to root when no data wrapper`() throws {
        let json = """
        {
          "available_balance": 200.0,
          "voucher_balance": 0.0,
          "cash_balance": 200.0
        }
        """
        let info = try KimiK2UsageFetcher._parseBalanceForTesting(Data(json.utf8))
        #expect(info?.availableBalance == 200.0)
        #expect(info?.cashBalance == 200.0)
    }

    @Test
    func `handles string numeric values`() throws {
        let json = """
        {
          "data": {
            "available_balance": "75.25",
            "voucher_balance": "0",
            "cash_balance": "75.25"
          }
        }
        """
        let info = try KimiK2UsageFetcher._parseBalanceForTesting(Data(json.utf8))
        #expect(info?.availableBalance == 75.25)
    }

    @Test
    func `handles missing fields with defaults`() throws {
        let json = """
        { "data": {} }
        """
        let info = try KimiK2UsageFetcher._parseBalanceForTesting(Data(json.utf8))
        #expect(info != nil)
        #expect(info?.availableBalance == 0)
        #expect(info?.voucherBalance == 0)
        #expect(info?.cashBalance == 0)
    }

    @Test
    func `invalid JSON throws parse error`() {
        let data = Data("not json".utf8)
        #expect {
            _ = try KimiK2UsageFetcher._parseBalanceForTesting(data)
        } throws: { error in
            guard case KimiK2UsageError.parseFailed = error else { return false }
            return true
        }
    }
}
