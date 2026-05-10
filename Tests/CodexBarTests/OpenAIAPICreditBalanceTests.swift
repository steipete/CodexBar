import Foundation
import Testing
@testable import CodexBarCore

struct OpenAIAPICreditBalanceTests {
    @Test
    func `parses credit grants balance`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let json = """
        {
          "object": "credit_summary",
          "total_granted": 25.5,
          "total_used": 7.25,
          "total_available": 18.25,
          "grants": {
            "object": "list",
            "data": [
              {
                "grant_amount": 10.0,
                "used_amount": 1.0,
                "effective_at": 1690000000,
                "expires_at": 1800000000
              }
            ]
          }
        }
        """

        let snapshot = try OpenAIAPICreditBalanceFetcher._parseSnapshotForTesting(Data(json.utf8), now: now)

        #expect(snapshot.totalGranted == 25.5)
        #expect(snapshot.totalUsed == 7.25)
        #expect(snapshot.totalAvailable == 18.25)
        #expect(snapshot.nextGrantExpiry == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test
    func `maps balance to usage snapshot`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let balance = OpenAIAPICreditBalanceSnapshot(
            totalGranted: 100,
            totalUsed: 40,
            totalAvailable: 60,
            nextGrantExpiry: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: now)

        let usage = balance.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 40)
        #expect(usage.primary?.resetDescription == "$60.00 available")
        #expect(usage.providerCost?.used == 40)
        #expect(usage.providerCost?.limit == 100)
        #expect(usage.identity?.providerID == .openai)
        #expect(usage.identity?.loginMethod == "API balance: $60.00")
    }
}
