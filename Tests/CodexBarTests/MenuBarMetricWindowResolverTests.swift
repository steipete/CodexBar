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
    func `automatic metric for kimi picks most constrained window`() {
        // Rate limit (primary) is 10%, Weekly (secondary) is 90%
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: "Rate limit"),
            secondary: RateWindow(usedPercent: 90, windowMinutes: nil, resetsAt: nil, resetDescription: "Weekly"),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .kimi,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.usedPercent == 90)
        #expect(window?.resetDescription == "Weekly")

        // Swapped: Rate limit (primary) is 95%, Weekly (secondary) is 10%
        let snapshot2 = UsageSnapshot(
            primary: RateWindow(usedPercent: 95, windowMinutes: 300, resetsAt: nil, resetDescription: "Rate limit"),
            secondary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: "Weekly"),
            updatedAt: Date())

        let window2 = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .kimi,
            snapshot: snapshot2,
            supportsAverage: false)

        #expect(window2?.usedPercent == 95)
        #expect(window2?.resetDescription == "Rate limit")
    }
}
