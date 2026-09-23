import Foundation
import Testing
@testable import CodexBarCore

struct GrokBotUsageSnapshotTests {
    private static let now = ISO8601DateFormatter().date(from: "2026-09-10T12:00:00Z")!

    @Test
    func `maps paid sand allowance to primary weekly window`() throws {
        let sand = CursorSandUsageStatus(
            currentPeriodStart: "2026-09-03T00:00:00.000Z",
            nextResetTimestampUtc: "2026-09-10T00:00:00.000Z",
            usagePercent: 42,
            hasAvailableUsage: true,
            includedLimitZero: false)
        let snapshot = try GrokBotUsageSnapshot.usageSnapshot(from: sand, now: Self.now)
        #expect(snapshot.primary?.usedPercent == 42)
        #expect(snapshot.primary?.windowMinutes == 10080)
        #expect(snapshot.secondary == nil)
    }

    @Test
    func `active trial without included limit still maps usage`() throws {
        let sand = CursorSandUsageStatus(
            currentPeriodStart: nil,
            nextResetTimestampUtc: nil,
            usagePercent: 14,
            hasAvailableUsage: true,
            hasNonZeroIncludedLimit: false,
            sandTrialExpiresAt: "2026-09-21T09:12:32.776Z")
        let snapshot = try GrokBotUsageSnapshot.usageSnapshot(from: sand, now: Self.now)
        #expect(snapshot.primary?.usedPercent == 14)
        #expect(snapshot.primary?.resetsAt == nil)
    }

    @Test
    func `missing allowance throws`() throws {
        let sand = CursorSandUsageStatus(
            currentPeriodStart: nil,
            nextResetTimestampUtc: nil,
            usagePercent: nil,
            hasAvailableUsage: false,
            includedLimitZero: true)
        #expect(throws: GrokBotProbeError.noAllowance) {
            try GrokBotUsageSnapshot.usageSnapshot(from: sand, now: Self.now)
        }
    }
}
