import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
extension StatusItemBalanceDisplayTests {
    @Test
    func `menu bar display text extracts Replicate month spend`() {
        let snapshot = ReplicateUsageSummary(
            currentMonthSpend: 12.4,
            currencyCode: "USD",
            creditBalance: 80,
            spendLimit: nil,
            username: "demo",
            updatedAt: Date())
            .toUsageSnapshot()

        #expect(StatusItemController.replicateSpendDisplayText(snapshot: snapshot) == "$12.40")
    }

    @Test
    func `menu bar display text ignores Replicate snapshot without spend detail`() {
        #expect(StatusItemController.replicateSpendDisplayText(snapshot: nil) == nil)

        let bareSnapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            updatedAt: Date(),
            identity: nil)
        #expect(StatusItemController.replicateSpendDisplayText(snapshot: bareSnapshot) == nil)
    }

    @Test
    func `menu bar display text shows Replicate month spend`() {
        let settings = self.makeSettings(
            suiteName: "StatusItemBalanceDisplayTests-replicate-spend",
            provider: .replicate)
        let (store, controller) = self.makeStoreAndController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        let snapshot = ReplicateUsageSummary(
            currentMonthSpend: 12.4,
            currencyCode: "USD",
            creditBalance: 80,
            spendLimit: nil,
            username: "demo",
            updatedAt: Date())
            .toUsageSnapshot()

        store._setSnapshotForTesting(snapshot, provider: .replicate)
        store._setErrorForTesting(nil, provider: .replicate)

        #expect(controller.menuBarDisplayText(for: .replicate, snapshot: snapshot) == "$12.40")
    }
}
