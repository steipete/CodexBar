import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MenuBarMetricWindowResolverTests {
    @Test
    func `automatic metric uses zai 5-hour token lane when it is most constrained`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 12, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 92, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .zai,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.usedPercent == 92)
    }

    @Test
    func `extra usage metric maps provider cost into a menu bar window`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 12, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 37.5,
                limit: 150,
                currencyCode: "USD",
                updatedAt: Date()),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .extraUsage,
            provider: .cursor,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.usedPercent == 25)
    }

    @Test
    func `automatic metric uses claude enterprise spend limit`() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 67.03,
                limit: 1000,
                currencyCode: "USD",
                period: "Spend limit",
                updatedAt: Date()),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .claude,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(abs((window?.usedPercent ?? 0) - 6.703) < 0.0001)
    }

    @Test
    func `automatic metric uses claude web spend limit placeholder`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 67.03,
                limit: 1000,
                currencyCode: "USD",
                period: "Monthly",
                updatedAt: Date()),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .claude,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(abs((window?.usedPercent ?? 0) - 6.703) < 0.0001)
    }

    @Test
    func `automatic metric keeps claude quota window when extra usage is optional`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 42, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 67.03,
                limit: 1000,
                currencyCode: "USD",
                period: "Monthly",
                updatedAt: Date()),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .claude,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.usedPercent == 42)
    }

    @Test
    func `automatic metric keeps claude zero quota window when reset exists`() {
        let reset = Date(timeIntervalSince1970: 1000)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: reset, resetDescription: "later"),
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 67.03,
                limit: 1000,
                currencyCode: "USD",
                period: "Monthly",
                updatedAt: Date()),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .claude,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.resetsAt == reset)
    }
}
