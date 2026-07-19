import CodexBarCore
import Foundation
import Testing

struct GroqUsageFetcherTests {
    @Test
    func `parses prometheus scalar response`() throws {
        let json = """
        {
          "status": "success",
          "data": {
            "result": [
              { "value": [1710000000, "2.5"] },
              { "value": [1710000000, "1.5"] }
            ]
          }
        }
        """

        let value = try GroqUsageFetcher._parseScalarForTesting(Data(json.utf8))

        #expect(value == 4)
    }

    @Test
    func `snapshot maps prometheus rates to menu windows`() {
        let snapshot = GroqUsageSnapshot(
            requestRatePerSecond: 2,
            inputTokenRatePerSecond: 100,
            outputTokenRatePerSecond: 50,
            promptCacheHitRatePerSecond: 3,
            updatedAt: Date(timeIntervalSince1970: 1))
            .toUsageSnapshot()

        #expect(snapshot.identity?.providerID == .groq)
        #expect(snapshot.identity?.loginMethod == "Prometheus metrics")
        #expect(snapshot.primary?.resetDescription == "120 req/min")
        #expect(snapshot.secondary?.resetDescription == "9000 tok/min")
        #expect(snapshot.tertiary?.resetDescription == "180 cache/min")
    }
}
