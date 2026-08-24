import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct NotchUsageOverlayModelTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let labels = ProviderRateWindowLabels(
        primary: "Session",
        secondary: "Weekly",
        tertiary: "Monthly",
        showsTertiary: true)

    @Test
    func `orders primary and secondary bars`() {
        let snapshot = UsageSnapshot(
            primary: Self.window(usedPercent: 20),
            secondary: Self.window(usedPercent: 40),
            updatedAt: self.now)

        let bars = NotchUsageOverlayModel.bars(
            snapshot: snapshot,
            labels: self.labels,
            showUsed: false,
            now: self.now)

        #expect(bars.map(\.title) == ["Session", "Weekly"])
        #expect(bars.map(\.percent) == [80, 60])
    }

    @Test
    func `provider accessibility summary carries every bar, not just the name`() {
        let row = NotchUsageOverlayModel.ProviderRow(
            id: .codex,
            name: "Codex",
            tint: .green,
            bars: [
                NotchUsageOverlayModel.Bar(
                    title: "Session",
                    percent: 80,
                    percentText: "80% left",
                    resetText: nil,
                    accessibilityLabel: "Session 80% left"),
                NotchUsageOverlayModel.Bar(
                    title: "Weekly",
                    percent: 60,
                    percentText: "60% left",
                    resetText: nil,
                    accessibilityLabel: "Weekly 60% left"),
            ],
            statusText: "resets at 9am")

        // The tile is one combined accessibility element, so the label must speak for the bars.
        #expect(row.accessibilitySummary == "Codex, resets at 9am, Session 80% left, Weekly 60% left")

        let bare = NotchUsageOverlayModel.ProviderRow(
            id: .claude, name: "Claude", tint: .green, bars: [], statusText: nil)
        #expect(bare.accessibilitySummary == "Claude")
    }

    @Test
    func `prefers the first known extra window over provider cost`() {
        let snapshot = UsageSnapshot(
            primary: Self.window(usedPercent: 10),
            secondary: Self.window(usedPercent: 20),
            tertiary: Self.window(usedPercent: 30),
            extraRateWindows: [
                NamedRateWindow(
                    id: "unknown",
                    title: "Unknown",
                    window: Self.window(usedPercent: 90),
                    usageKnown: false),
                NamedRateWindow(
                    id: "team",
                    title: "Team",
                    window: Self.window(usedPercent: 45)),
            ],
            providerCost: ProviderCostSnapshot(
                used: 99,
                limit: 100,
                currencyCode: "USD",
                period: "Monthly",
                updatedAt: self.now),
            updatedAt: self.now)

        let bars = NotchUsageOverlayModel.bars(
            snapshot: snapshot,
            labels: self.labels,
            showUsed: true,
            now: self.now)

        #expect(bars.count == 4)
        #expect(bars.last?.title == "Team")
        #expect(bars.last?.percent == 45)
    }

    @Test
    func `uses provider cost as the fourth bar when no extra window is known`() throws {
        let snapshot = UsageSnapshot(
            primary: Self.window(usedPercent: 10),
            secondary: Self.window(usedPercent: 20),
            tertiary: Self.window(usedPercent: 30),
            providerCost: ProviderCostSnapshot(
                used: 25,
                limit: 100,
                currencyCode: "USD",
                period: "Monthly",
                updatedAt: self.now),
            updatedAt: self.now)

        let bars = NotchUsageOverlayModel.bars(
            snapshot: snapshot,
            labels: self.labels,
            showUsed: true,
            now: self.now)

        let costBar = try #require(bars.last)
        #expect(bars.count == 4)
        #expect(costBar.title == "Monthly")
        #expect(costBar.percent == 25)
        #expect(costBar.resetText == "$25.00")
    }

    @Test
    func `clamps usage and flips fill direction`() throws {
        let snapshot = UsageSnapshot(
            primary: Self.window(usedPercent: 125),
            secondary: nil,
            updatedAt: self.now)

        let usedBar = try #require(NotchUsageOverlayModel.bars(
            snapshot: snapshot,
            labels: self.labels,
            showUsed: true,
            now: self.now).first)
        let remainingBar = try #require(NotchUsageOverlayModel.bars(
            snapshot: snapshot,
            labels: self.labels,
            showUsed: false,
            now: self.now).first)

        #expect(usedBar.percent == 100)
        #expect(remainingBar.percent == 0)
    }

    private static func window(usedPercent: Double) -> RateWindow {
        RateWindow(
            usedPercent: usedPercent,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: nil)
    }
}
