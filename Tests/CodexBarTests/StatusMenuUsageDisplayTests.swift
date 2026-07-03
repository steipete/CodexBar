import CodexBarCore
import Testing
@testable import CodexBar

extension StatusMenuTests {
    @Test
    func `overview card model follows usage display preference`() throws {
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        settings.usageBarsShowUsed = false
        let remainingMetric = try #require(controller.menuCardModel(for: .codex)?.metrics.first { $0.id == "primary" })
        #expect(remainingMetric.percent == 78)
        #expect(remainingMetric.percentStyle.rawValue == "left")

        settings.usageBarsShowUsed = true
        let usedMetric = try #require(controller.menuCardModel(for: .codex)?.metrics.first { $0.id == "primary" })
        #expect(usedMetric.percent == 22)
        #expect(usedMetric.percentStyle.rawValue == "used")
    }
}
