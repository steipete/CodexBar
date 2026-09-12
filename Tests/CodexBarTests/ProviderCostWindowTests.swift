import Foundation
import Testing
@testable import CodexBarCore

struct ProviderCostWindowTests {
    @Test(arguments: [(-5.0, 0.0), (0, 0), (25, 25), (100, 100), (150, 100)])
    func `spend budget meters clamp usage and retain reset metadata`(used: Double, expected: Double) throws {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let cost = ProviderCostSnapshot(used: used, limit: 100, currencyCode: "USD", resetsAt: reset, updatedAt: reset)
        let window = try #require(cost.spendLimitWindow)
        #expect(window.usedPercent == expected)
        #expect(window.resetsAt == reset)
        #expect(window.windowMinutes == nil)
        #expect(window.resetDescription == nil)
        #expect(!window.isSyntheticPlaceholder)
    }

    @Test(arguments: [0.0, -1.0, Double.nan])
    func `balance only or invalid limits never become quota meters`(limit: Double) {
        let cost = ProviderCostSnapshot(used: 10, limit: limit, currencyCode: "USD", updatedAt: .now)
        #expect(cost.spendLimitWindow == nil)
    }
}
