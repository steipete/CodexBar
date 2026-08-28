import Foundation
import Testing
@testable import CodexBarCore

struct MiMoWindowMinutesTests {
    @Test
    func `monthly token quota carries a monthly window for pace history`() {
        // With a real period end, the monthly quota window carries a monthly windowMinutes so it
        // feeds the plan-utilization history + pace forecast (parity with Codex/Claude). Without a
        // period end there is nothing to reset against, so no window is claimed.
        let withPeriod = MiMoUsageSnapshot(
            balance: 0,
            currency: "USD",
            planPeriodEnd: Date(timeIntervalSince1970: 1_742_771_200),
            tokenUsed: 10,
            tokenLimit: 100,
            tokenPercent: 0.1,
            updatedAt: Date(timeIntervalSince1970: 1_742_000_000))
        #expect(withPeriod.toUsageSnapshot().primary?.windowMinutes == 30 * 24 * 60)

        let noPeriod = MiMoUsageSnapshot(
            balance: 0,
            currency: "USD",
            tokenUsed: 10,
            tokenLimit: 100,
            tokenPercent: 0.1,
            updatedAt: Date(timeIntervalSince1970: 1_742_000_000))
        #expect(noPeriod.toUsageSnapshot().primary?.windowMinutes == nil)
    }
}
