import Foundation
import Testing
@testable import CodexBarCore

struct CrofCreditsOnlyLinuxTests {
    @Test
    func `credits-only API payload maps balance as primary without request quota`() throws {
        let json = """
        {
          "credits":9.0441,
          "requests_plan":null,
          "usable_requests":null,
          "usage":{
            "deepseek-v4-flash":{
              "cached_tokens":0,
              "input_tokens":23,
              "output_tokens":132,
              "total_tokens":155
            }
          }
        }
        """

        let snapshot = try CrofUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        let usage = snapshot.toUsageSnapshot()

        #expect(snapshot.credits == 9.0441)
        #expect(snapshot.requestsPlan == nil)
        #expect(snapshot.usableRequests == nil)
        #expect(usage.primary?.usedPercent == 0)
        #expect(usage.primary?.windowMinutes == nil)
        #expect(usage.primary?.resetsAt == nil)
        #expect(usage.primary?.resetDescription == "$9.04")
        #expect(usage.secondary == nil)
        #expect(CrofProviderDescriptor.primaryLabel(snapshot: usage) == "Credits")
    }

    @Test
    func `zero credit balance is exhausted without inventing a reset window`() {
        let usage = CrofUsageSnapshot(credits: 0).toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.primary?.windowMinutes == nil)
        #expect(usage.primary?.resetsAt == nil)
        #expect(usage.primary?.resetDescription == "$0.00")
        #expect(usage.secondary == nil)
        #expect(CrofProviderDescriptor.primaryLabel(snapshot: usage) == "Credits")
    }

    @Test
    func `optional request quota still preferred when present`() {
        let usage = CrofUsageSnapshot(
            credits: 10,
            requestsPlan: 1000,
            usableRequests: 998,
            updatedAt: Date(timeIntervalSince1970: 1_777_800_000)).toUsageSnapshot()

        #expect(usage.primary?.windowMinutes == 1440)
        #expect(usage.primary?.resetDescription == "998 requests left")
        #expect(usage.secondary?.resetDescription == "$10.00")
        #expect(CrofProviderDescriptor.primaryLabel(snapshot: usage) != "Credits")
    }
}
