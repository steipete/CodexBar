import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct DeepInfraMenuBarMetricWindowResolverTests {
    @Test
    func `automatic metric uses billing cycle spend against a positive limit`() {
        let reset = Date(timeIntervalSince1970: 2000)
        let snapshot = Self.snapshot(used: 25, limit: 100, resetsAt: reset)

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .deepinfra,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.usedPercent == 25)
        #expect(window?.resetsAt == reset)
    }

    @Test
    func `automatic metric reports zero when billing cycle spend is zero`() {
        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .deepinfra,
            snapshot: Self.snapshot(used: 0, limit: 100),
            supportsAverage: false)

        #expect(window?.usedPercent == 0)
    }

    @Test
    func `automatic metric clamps over limit spend`() {
        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .deepinfra,
            snapshot: Self.snapshot(used: 125, limit: 100),
            supportsAverage: false)

        #expect(window?.usedPercent == 100)
    }

    @Test
    func `automatic metric keeps balance health without a positive finite limit`() {
        for limit in [nil, 0, -1, .infinity, .nan] as [Double?] {
            let snapshot = Self.snapshot(used: 25, limit: limit, primaryUsedPercent: 73)
            let window = MenuBarMetricWindowResolver.rateWindow(
                preference: .automatic,
                provider: .deepinfra,
                snapshot: snapshot,
                supportsAverage: false)

            #expect(window?.usedPercent == 73)
            #expect(window?.resetDescription == "Balance health")
        }
    }

    @Test
    func `spending limit projection does not affect explicit metrics or other providers`() {
        let snapshot = Self.snapshot(used: 25, limit: 100, primaryUsedPercent: 73)

        let explicit = MenuBarMetricWindowResolver.rateWindow(
            preference: .primary,
            provider: .deepinfra,
            snapshot: snapshot,
            supportsAverage: false)
        let otherProvider = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .deepseek,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(explicit?.usedPercent == 73)
        #expect(otherProvider?.usedPercent == 73)
    }

    private static func snapshot(
        used: Double,
        limit: Double?,
        primaryUsedPercent: Double = 0,
        resetsAt: Date? = nil) -> UsageSnapshot
    {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: primaryUsedPercent,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "Balance health"),
            secondary: nil,
            providerCost: limit.map {
                ProviderCostSnapshot(
                    used: used,
                    limit: $0,
                    currencyCode: "USD",
                    period: "Billing cycle",
                    resetsAt: resetsAt,
                    updatedAt: Date())
            },
            updatedAt: Date())
    }
}
