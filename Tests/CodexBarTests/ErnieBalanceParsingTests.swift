import Foundation
import Testing
@testable import CodexBarCore

struct ErnieBalanceParsingTests {
    @Test
    func `parses standard balance response`() throws {
        let json = """
        {
          "data": {
            "available_balance": 85.50,
            "used_balance": 14.50,
            "total_balance": 100.00
          }
        }
        """
        let info = try ErnieUsageFetcher._parseBalanceForTesting(Data(json.utf8))
        #expect(info.availableBalance == 85.50)
        #expect(info.usedBalance == 14.50)
        #expect(info.totalBalance == 100.00)
    }

    @Test
    func `parses camelCase balance response`() throws {
        let json = """
        {
          "data": {
            "availableBalance": 50.0,
            "usedBalance": 50.0,
            "totalBalance": 100.0
          }
        }
        """
        let info = try ErnieUsageFetcher._parseBalanceForTesting(Data(json.utf8))
        #expect(info.availableBalance == 50.0)
        #expect(info.totalBalance == 100.0)
    }

    @Test
    func `falls back to root when no data wrapper`() throws {
        let json = """
        {
          "available_balance": 200.0,
          "used_balance": 0.0,
          "total_balance": 200.0
        }
        """
        let info = try ErnieUsageFetcher._parseBalanceForTesting(Data(json.utf8))
        #expect(info.availableBalance == 200.0)
    }

    @Test
    func `derives total from available plus used`() throws {
        let json = """
        {
          "data": {
            "available_balance": 60.0,
            "used_balance": 40.0
          }
        }
        """
        let info = try ErnieUsageFetcher._parseBalanceForTesting(Data(json.utf8))
        #expect(info.totalBalance == 100.0)
    }

    @Test
    func `handles string numeric values`() throws {
        let json = """
        {
          "data": {
            "available_balance": "75.25",
            "used_balance": "24.75",
            "total_balance": "100.00"
          }
        }
        """
        let info = try ErnieUsageFetcher._parseBalanceForTesting(Data(json.utf8))
        #expect(info.availableBalance == 75.25)
    }

    @Test
    func `invalid JSON throws parse error`() {
        let data = Data("not json".utf8)
        #expect {
            _ = try ErnieUsageFetcher._parseBalanceForTesting(data)
        } throws: { error in
            guard case ErnieUsageError.parseFailed = error else { return false }
            return true
        }
    }
}
