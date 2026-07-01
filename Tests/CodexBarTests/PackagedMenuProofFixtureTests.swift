import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct PackagedMenuProofFixtureTests {
    @Test
    func `dashboard cost fixture traverses packaged menu model deterministically`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-packaged-menu-proof-\(UUID().uuidString)", isDirectory: true)
        let runtime = try #require(PackagedMenuProofFixture.makeRuntimeIfRequested(environment: [
            PackagedMenuProofFixture.environmentKey: "codex-dashboard-cost",
            "CODEXBAR_PACKAGED_MENU_FIXTURE_ROOT": root.path,
        ]))
        defer {
            StatusItemController.resetCodexAccountMenuProjectionRevalidationEnabledForTesting()
            try? FileManager.default.removeItem(at: root)
        }

        let snapshot = try #require(runtime.store.tokenSnapshot(for: .codex))
        #expect(snapshot.valueBasis == .codexDashboardCredits)
        #expect(snapshot.historyDays == 30)
        #expect(snapshot.daily.count == 30)
        #expect(snapshot.sessionCostUSD == 10)
        #expect(snapshot.last30DaysCostUSD == 138)

        let controller = StatusItemController(
            store: runtime.store,
            settings: runtime.settings,
            account: runtime.account,
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        defer { controller.releaseStatusItemsForTesting() }

        let model = try #require(controller.menuCardModel(for: .codex))
        let dashboard = try #require(model.inlineUsageDashboard)
        #expect(dashboard.kpis.contains { $0.title == "Today" && $0.value == "≈ $10.00" })
        #expect(dashboard.kpis.contains { $0.title == "30d cost" && $0.value == "≈ $138.00" })
        #expect(model.tokenUsage?.sessionLine == "Est. total (Today): ≈ $10.00")
        #expect(model.tokenUsage?.monthLine == "Est. total (Last 30 days): ≈ $138.00")
        #expect(model.tokenUsage?.hintLine?.contains("25 credits = $1") == true)
    }
}
