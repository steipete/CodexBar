import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite
struct UsageChangeDetectionTests {
    @Test
    func ignoresUpdatedAtOnly() {
        let window = Self.makeWindow(usedPercent: 25)
        let snapshotA = UsageSnapshot(
            primary: window,
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 100))
        let snapshotB = UsageSnapshot(
            primary: window,
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 200))

        let changed = UsageStore.didUsageChange(previous: snapshotA, next: snapshotB, provider: .codex)
        #expect(changed == false)
    }

    @Test
    func detectsUsagePercentChange() {
        let snapshotA = UsageSnapshot(
            primary: Self.makeWindow(usedPercent: 25),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 100))
        let snapshotB = UsageSnapshot(
            primary: Self.makeWindow(usedPercent: 35),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 200))

        let changed = UsageStore.didUsageChange(previous: snapshotA, next: snapshotB, provider: .codex)
        #expect(changed)
    }

    @Test
    func detectsProviderCostChange() {
        let window = Self.makeWindow(usedPercent: 10)
        let costA = ProviderCostSnapshot(
            used: 1.0,
            limit: 10.0,
            currencyCode: "USD",
            period: "monthly",
            resetsAt: nil,
            updatedAt: Date(timeIntervalSince1970: 50))
        let costB = ProviderCostSnapshot(
            used: 2.0,
            limit: 10.0,
            currencyCode: "USD",
            period: "monthly",
            resetsAt: nil,
            updatedAt: Date(timeIntervalSince1970: 60))

        let snapshotA = UsageSnapshot(
            primary: window,
            secondary: nil,
            providerCost: costA,
            updatedAt: Date(timeIntervalSince1970: 100))
        let snapshotB = UsageSnapshot(
            primary: window,
            secondary: nil,
            providerCost: costB,
            updatedAt: Date(timeIntervalSince1970: 200))

        let changed = UsageStore.didUsageChange(previous: snapshotA, next: snapshotB, provider: .cursor)
        #expect(changed)
    }

    @Test
    func detectsZaiUsageChange() {
        let window = Self.makeWindow(usedPercent: 10)
        let tokenA = ZaiLimitEntry(
            type: .tokensLimit,
            unit: .days,
            number: 30,
            usage: 100,
            currentValue: 100,
            remaining: 900,
            percentage: 10,
            usageDetails: [],
            nextResetTime: Date(timeIntervalSince1970: 1_000))
        let tokenB = ZaiLimitEntry(
            type: .tokensLimit,
            unit: .days,
            number: 30,
            usage: 120,
            currentValue: 120,
            remaining: 880,
            percentage: 12,
            usageDetails: [],
            nextResetTime: Date(timeIntervalSince1970: 1_000))
        let zaiA = ZaiUsageSnapshot(
            tokenLimit: tokenA,
            timeLimit: nil,
            planName: "Pro",
            updatedAt: Date())
        let zaiB = ZaiUsageSnapshot(
            tokenLimit: tokenB,
            timeLimit: nil,
            planName: "Pro",
            updatedAt: Date())

        let snapshotA = UsageSnapshot(
            primary: window,
            secondary: nil,
            providerCost: nil,
            zaiUsage: zaiA,
            updatedAt: Date(timeIntervalSince1970: 100))
        let snapshotB = UsageSnapshot(
            primary: window,
            secondary: nil,
            providerCost: nil,
            zaiUsage: zaiB,
            updatedAt: Date(timeIntervalSince1970: 200))

        let changed = UsageStore.didUsageChange(previous: snapshotA, next: snapshotB, provider: .zai)
        #expect(changed)
    }

    private static func makeWindow(usedPercent: Double) -> RateWindow {
        RateWindow(
            usedPercent: usedPercent,
            windowMinutes: 60,
            resetsAt: Date(timeIntervalSince1970: 1_000),
            resetDescription: "Hourly")
    }
}
