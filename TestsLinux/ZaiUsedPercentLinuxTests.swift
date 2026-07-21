#if os(Linux)
import CodexBarCore
import Foundation
import Testing

struct ZaiUsedPercentLinuxTests {
    /// usage == nil forces computedUsedPercent to return nil, exercising the raw-percentage fallback.
    private func fallbackUsedPercent(_ percentage: Double) -> Double {
        ZaiLimitEntry(
            type: .tokensLimit,
            unit: .hours,
            number: 5,
            usage: nil,
            currentValue: nil,
            remaining: nil,
            percentage: percentage,
            usageDetails: [],
            nextResetTime: nil).usedPercent
    }

    @Test
    func `raw percentage fallback clamps above 100`() {
        #expect(self.fallbackUsedPercent(150) == 100)
    }

    @Test
    func `raw percentage fallback clamps below 0`() {
        #expect(self.fallbackUsedPercent(-5) == 0)
    }

    @Test
    func `raw percentage fallback preserves an in-range value`() {
        #expect(self.fallbackUsedPercent(42) == 42)
    }

    @Test
    func `computed path takes precedence and ignores the raw percentage`() {
        // usage(limit)=100, currentValue(used)=25 -> computed 25%, so the raw 999 must not leak.
        let entry = ZaiLimitEntry(
            type: .tokensLimit,
            unit: .hours,
            number: 5,
            usage: 100,
            currentValue: 25,
            remaining: nil,
            percentage: 999,
            usageDetails: [],
            nextResetTime: nil)
        #expect(entry.usedPercent == 25)
    }
}
#endif
