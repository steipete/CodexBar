import CodexBarCore
import Foundation
import Testing

@Suite
struct PoeUsageFetcherTests {
    @Test
    func parseBalanceSucceeds() throws {
        let json = """
        {"current_point_balance": 295932027}
        """
        let data = json.data(using: .utf8)!
        let snapshot = try PoeUsageFetcher._parseBalanceForTesting(data)
        #expect(snapshot.pointBalance == 295_932_027)
    }

    @Test
    func parseBalanceHandlesZero() throws {
        let json = """
        {"current_point_balance": 0}
        """
        let data = json.data(using: .utf8)!
        let snapshot = try PoeUsageFetcher._parseBalanceForTesting(data)
        #expect(snapshot.pointBalance == 0)
    }

    @Test
    func parseBalanceHandlesLargeValue() throws {
        let json = """
        {"current_point_balance": 10000000000}
        """
        let data = json.data(using: .utf8)!
        let snapshot = try PoeUsageFetcher._parseBalanceForTesting(data)
        #expect(snapshot.pointBalance == 10_000_000_000)
    }

    @Test
    func parseBalanceFailsOnInvalidJSON() throws {
        let json = """
        {"invalid": "response"}
        """
        let data = json.data(using: .utf8)!
        #expect(throws: PoeUsageError.self) {
            try PoeUsageFetcher._parseBalanceForTesting(data)
        }
    }

    @Test
    func parseBalanceFailsOnMalformedJSON() throws {
        let json = "not json at all"
        let data = json.data(using: .utf8)!
        #expect(throws: PoeUsageError.self) {
            try PoeUsageFetcher._parseBalanceForTesting(data)
        }
    }
}
