import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension StatusItemBalanceDisplayTests {
    @Test(arguments: [MenuBarDisplayMode.percent, .pace, .both, .resetTime])
    func `claude prepaid balance never replaces the legacy subscription text`(mode: MenuBarDisplayMode) {
        let settings = self.makeSettings(
            suiteName: "StatusItemBalanceDisplayTests-claude-prepaid-\(mode.rawValue)",
            provider: .claude)
        settings.menuBarDisplayMode = mode
        let (store, controller) = self.makeStoreAndController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        let now = Date(timeIntervalSince1970: 1_792_022_400) // October 15, 2026, UTC.
        let session = RateWindow(
            usedPercent: 12,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(3600),
            resetDescription: nil)
        let subscriptionOnly = UsageSnapshot(primary: session, secondary: nil, updatedAt: now)
        let withBalance = UsageSnapshot(
            primary: session,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 0,
                limit: 0,
                currencyCode: "USD",
                balance: 76.65,
                updatedAt: now),
            updatedAt: now)

        store._setSnapshotForTesting(withBalance, provider: .claude)
        store._setErrorForTesting(nil, provider: .claude)

        let expected = controller.menuBarDisplayText(for: .claude, snapshot: subscriptionOnly, now: now)
        #expect(expected != nil)
        #expect(controller.menuBarDisplayText(for: .claude, snapshot: withBalance, now: now) == expected)
    }

    @Test
    func `claude prepaid balance stays out of the legacy text without a quota window`() {
        let settings = self.makeSettings(
            suiteName: "StatusItemBalanceDisplayTests-claude-prepaid-only",
            provider: .claude)
        let (store, controller) = self.makeStoreAndController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        let now = Date(timeIntervalSince1970: 1_792_022_400) // October 15, 2026, UTC.
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 0,
                limit: 0,
                currencyCode: "USD",
                balance: 76.65,
                updatedAt: now),
            updatedAt: now)

        store._setSnapshotForTesting(snapshot, provider: .claude)
        store._setErrorForTesting(nil, provider: .claude)

        let withoutBalance = UsageSnapshot(primary: nil, secondary: nil, updatedAt: now)
        #expect(controller.menuBarDisplayText(for: .claude, snapshot: snapshot, now: now)
            == controller.menuBarDisplayText(for: .claude, snapshot: withoutBalance, now: now))
    }

    @Test
    func `claude prepaid balance follows the optional credits setting in status item and preview`() {
        let settings = self.makeSettings(
            suiteName: "StatusItemBalanceDisplayTests-claude-prepaid-optional-credits",
            provider: .claude)
        let layout = MenuBarLayout(lines: [[.balance]])
        settings.setMenuBarLayout(layout, for: nil)
        settings.menuBarShowsBrandIconWithPercent = true
        settings.showOptionalCreditsAndExtraUsage = true
        let (store, controller) = self.makeStoreAndController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        let now = Date(timeIntervalSince1970: 1_792_022_400) // October 15, 2026, UTC.
        // A snapshot retained from before the setting was turned off still carries the balance.
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 0,
                limit: 0,
                currencyCode: "USD",
                balance: 76.65,
                updatedAt: now),
            updatedAt: now)

        store._setSnapshotForTesting(snapshot, provider: .claude)
        store._setErrorForTesting(nil, provider: .claude)

        func renderData() -> [MenuBarLayoutRenderData] {
            [
                controller.menuBarLayoutRenderData(provider: .claude, snapshot: snapshot, warningFlash: false),
                MenuBarLayoutPreview(layout: layout, provider: .claude, settings: settings, store: store)
                    .liveData(provider: .claude, snapshot: snapshot),
            ]
        }

        for data in renderData() {
            #expect(data.balance == "$76.65")
            #expect(data.metrics.balanceRemainingUSD == 76.65)
        }
        let visibleSignature = controller.storeIconObservationSignature()

        settings.showOptionalCreditsAndExtraUsage = false

        for data in renderData() {
            #expect(data.balance == nil)
            #expect(data.automaticText == nil)
            #expect(data.metrics.balanceRemainingUSD == nil)
        }
        #expect(controller.storeIconObservationSignature() != visibleSignature)
    }
}
