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
    func `bar accessibility labels speak the visible values`() throws {
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: "Resets 4:40am"),
            secondary: Self.window(usedPercent: 40),
            updatedAt: self.now)

        let bars = NotchUsageOverlayModel.bars(
            snapshot: snapshot,
            labels: self.labels,
            showUsed: false,
            now: self.now)
        let primary = try #require(bars.first)
        let secondary = try #require(bars.last)

        // The label is derived from the visible pieces, so VoiceOver hears the same figures a
        // sighted user sees — the row title alone would drop the percentage and reset text.
        #expect(primary.accessibilityLabel == "Session, \(primary.percentText), Resets 4:40am")
        #expect(secondary.resetText == nil)
        #expect(secondary.accessibilityLabel == "Weekly, \(secondary.percentText)")
        #expect(primary.percentText.contains("80"))
    }

    @Test
    func `provider accessibility summary carries every bar, not just the name`() {
        let snapshot = UsageSnapshot(
            primary: Self.window(usedPercent: 20),
            secondary: Self.window(usedPercent: 40),
            updatedAt: self.now)
        let bars = NotchUsageOverlayModel.bars(
            snapshot: snapshot,
            labels: self.labels,
            showUsed: false,
            now: self.now)

        let row = NotchUsageOverlayModel.ProviderRow(
            id: .codex,
            name: "Codex",
            tint: .green,
            bars: bars,
            statusText: nil)

        // The tile is one combined accessibility element, so the summary must speak for the bars.
        #expect(row.accessibilitySummary
            == "Codex, \(bars[0].accessibilityLabel), \(bars[1].accessibilityLabel)")

        let bare = NotchUsageOverlayModel.ProviderRow(
            id: .claude, name: "Claude", tint: .green, bars: [], statusText: "No usage fetched yet")
        #expect(bare.accessibilitySummary == "Claude, No usage fetched yet")
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
