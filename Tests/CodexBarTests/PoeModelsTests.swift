import CodexBarCore
import Foundation
import Testing

@Suite
struct PoeModelsTests {
    @Test
    func formatPointsRawNumbers() {
        #expect(PoeUsageSnapshot.formatPoints(0) == "0 pts")
        #expect(PoeUsageSnapshot.formatPoints(1) == "1 pts")
        #expect(PoeUsageSnapshot.formatPoints(500) == "500 pts")
        #expect(PoeUsageSnapshot.formatPoints(999) == "999 pts")
    }

    @Test
    func formatPointsThousands() {
        #expect(PoeUsageSnapshot.formatPoints(1_000) == "1.0K pts")
        #expect(PoeUsageSnapshot.formatPoints(1_500) == "1.5K pts")
        #expect(PoeUsageSnapshot.formatPoints(10_000) == "10.0K pts")
        #expect(PoeUsageSnapshot.formatPoints(999_999) == "1000.0K pts")
    }

    @Test
    func formatPointsMillions() {
        #expect(PoeUsageSnapshot.formatPoints(1_000_000) == "1.0M pts")
        #expect(PoeUsageSnapshot.formatPoints(1_500_000) == "1.5M pts")
        #expect(PoeUsageSnapshot.formatPoints(295_932_027) == "295.9M pts")
        #expect(PoeUsageSnapshot.formatPoints(999_999_999) == "1000.0M pts")
    }

    @Test
    func formatPointsBillions() {
        #expect(PoeUsageSnapshot.formatPoints(1_000_000_000) == "1.0B pts")
        #expect(PoeUsageSnapshot.formatPoints(1_500_000_000) == "1.5B pts")
        #expect(PoeUsageSnapshot.formatPoints(10_000_000_000) == "10.0B pts")
    }

    @Test
    func toUsageSnapshotCreatesValidSnapshot() {
        let snapshot = PoeUsageSnapshot(pointBalance: 295_932_027, updatedAt: Date())
        let usageSnapshot = snapshot.toUsageSnapshot()

        #expect(usageSnapshot.primary?.resetDescription == "295.9M pts")
        #expect(usageSnapshot.primary?.usedPercent == 0)
        #expect(usageSnapshot.identity?.providerID == .poe)
        #expect(usageSnapshot.secondary == nil)
        #expect(usageSnapshot.tertiary == nil)
    }
}
