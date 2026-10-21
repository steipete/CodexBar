import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension StatusItemBalanceDisplayTests {
    @Test(arguments: [MenuBarDisplayMode.pace, .both])
    func `kiro menu bar follows the global pace display mode`(mode: MenuBarDisplayMode) {
        let settings = self.makeSettings(
            suiteName: "StatusItemBalanceDisplayTests-kiro-pace-\(mode.rawValue)",
            provider: .kiro)
        settings.menuBarDisplayMode = mode
        settings.kiroMenuBarDisplayMode = .automatic
        let (store, controller) = self.makeStoreAndController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        let now = Date(timeIntervalSince1970: 1_792_022_400) // October 15, 2026, UTC.
        let reset = Date(timeIntervalSince1970: 1_793_491_200) // November 1, 2026, UTC.
        let snapshot = KiroUsageSnapshot(
            planName: "KIRO POWER",
            creditsUsed: 6000,
            creditsTotal: 10000,
            creditsPercent: 60,
            bonusCreditsUsed: nil,
            bonusCreditsTotal: nil,
            bonusExpiryDays: nil,
            resetsAt: reset,
            updatedAt: now).toUsageSnapshot()

        store._setSnapshotForTesting(snapshot, provider: .kiro)
        store._setErrorForTesting(nil, provider: .kiro)

        let displayText = controller.menuBarDisplayText(for: .kiro, snapshot: snapshot, now: now)

        #expect(displayText == (mode == .pace ? "+15%" : "4000 · +15%"))
        settings.kiroMenuBarDisplayMode = .hidden
        #expect(controller.menuBarDisplayText(for: .kiro, snapshot: snapshot, now: now) == nil)
    }
}
