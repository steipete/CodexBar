import CodexBarCore
import Foundation
import Testing

struct DoubaoProviderTests {
    @Test
    func `usage snapshot exposes request usage window`() {
        let resetDate = Date(timeIntervalSince1970: 1_742_771_200)
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 80,
            limitRequests: 100,
            resetTime: resetDate,
            updatedAt: resetDate,
            apiKeyValid: true)

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 20)
        #expect(usage.primary?.resetDescription == "20/100 requests")
        #expect(usage.primary?.resetsAt == resetDate)
        #expect(usage.identity?.providerID == .doubao)
    }

    @Test
    func `usage snapshot shows active key when headers are absent`() {
        let now = Date(timeIntervalSince1970: 1_742_771_200)
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 0,
            limitRequests: 0,
            resetTime: nil,
            updatedAt: now,
            apiKeyValid: true)

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 0)
        #expect(usage.primary?.resetDescription == "Active - check dashboard for details")
    }
}
