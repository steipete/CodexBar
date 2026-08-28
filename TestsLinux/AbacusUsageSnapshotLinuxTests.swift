#if os(Linux)
import Foundation
import Testing
@testable import CodexBarCore

struct AbacusUsageSnapshotLinuxTests {
    @Test
    func `in-range credit usage maps to its percent`() {
        let snapshot = AbacusUsageSnapshot(creditsUsed: 250, creditsTotal: 1000)
        let usage = snapshot.toUsageSnapshot()
        #expect(abs((usage.primary?.usedPercent ?? 0) - 25) < 0.01)
    }

    @Test
    func `credit overage clamps used percent to 100`() {
        // A usage-based plan in overage (or a shrunk grant) reports used > total.
        // The percent must cap at 100 like every sibling credit provider, instead
        // of flowing 150 into RateWindow.usedPercent (which does not clamp).
        let snapshot = AbacusUsageSnapshot(creditsUsed: 15000, creditsTotal: 10000)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 100)
    }
}
#endif
