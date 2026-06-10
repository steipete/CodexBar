import Foundation
import Testing
@testable import CodexBarCore

struct DoubaoUsageSnapshotTests {
    @Test
    func `normal usage with both headers present and non-empty reports correct percent`() {
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 750,
            limitRequests: 1000,
            resetTime: nil,
            updatedAt: Date(),
            apiKeyValid: true)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.primary?.resetDescription == "250/1000 requests")
    }

    @Test
    func `boundary normal usage at near-full reports correct percent`() {
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 1,
            limitRequests: 1000,
            resetTime: nil,
            updatedAt: Date(),
            apiKeyValid: true)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 99.9)
        #expect(usage.primary?.resetDescription == "999/1000 requests")
    }

    @Test
    func `unreliable headers limit positive remaining zero falls back to Active hint`() {
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 0,
            limitRequests: 1000,
            resetTime: nil,
            updatedAt: Date(),
            apiKeyValid: true)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 0)
        #expect(usage.primary?.resetDescription == "Active - check dashboard for details")
    }

    @Test
    func `explicit rate limit with zero remaining reports exhausted quota`() {
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 0,
            limitRequests: 1000,
            resetTime: nil,
            updatedAt: Date(),
            apiKeyValid: true,
            isRateLimited: true)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.primary?.resetDescription == "1000/1000 requests")
    }

    @Test
    func `both headers missing but key valid falls back to Active hint`() {
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 0,
            limitRequests: 0,
            resetTime: nil,
            updatedAt: Date(),
            apiKeyValid: true)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 0)
        #expect(usage.primary?.resetDescription == "Active - check dashboard for details")
    }

    @Test
    func `invalid key with no headers reports No usage data`() {
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 0,
            limitRequests: 0,
            resetTime: nil,
            updatedAt: Date(),
            apiKeyValid: false)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 0)
        #expect(usage.primary?.resetDescription == "No usage data")
    }

    @Test
    func `provider identity is correctly tagged as doubao`() {
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 500,
            limitRequests: 1000,
            resetTime: nil,
            updatedAt: Date(),
            apiKeyValid: true)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.identity?.providerID == .doubao)
        #expect(usage.identity?.accountEmail == nil)
    }
}
