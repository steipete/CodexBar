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
}
