import CodexBarCore
import Foundation
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

    @Test
    func `status menu card follows claude daily routines visibility`() throws {
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        let now = Date()
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 22,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(1800),
                    resetDescription: nil),
                secondary: nil,
                tertiary: nil,
                extraRateWindows: [
                    NamedRateWindow(
                        id: "claude-weekly-scoped-fable",
                        title: "Fable only",
                        window: RateWindow(
                            usedPercent: 30,
                            windowMinutes: 10080,
                            resetsAt: now.addingTimeInterval(3600),
                            resetDescription: nil)),
                    NamedRateWindow(
                        id: "claude-routines",
                        title: "Daily Routines",
                        window: RateWindow(
                            usedPercent: 40,
                            windowMinutes: 10080,
                            resetsAt: now.addingTimeInterval(7200),
                            resetDescription: nil)),
                ],
                updatedAt: now),
            provider: .claude)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        #expect(controller.menuCardModel(for: .claude)?.metrics.contains { $0.id == "claude-routines" } == true)

        settings.claudeDailyRoutinesUsageVisible = false
        let hiddenModel = try #require(controller.menuCardModel(for: .claude))
        #expect(!hiddenModel.metrics.contains { $0.id == "claude-routines" })
        #expect(hiddenModel.metrics.contains { $0.id == "claude-weekly-scoped-fable" })
    }

    @Test
    func `status menu card follows codex spark visibility`() throws {
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        let now = Date()
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 22,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(1800),
                    resetDescription: nil),
                secondary: nil,
                tertiary: nil,
                extraRateWindows: [
                    NamedRateWindow(
                        id: CodexAdditionalRateLimitMapper.sparkWindowID,
                        title: "Codex Spark 5-hour",
                        window: RateWindow(
                            usedPercent: 40,
                            windowMinutes: 300,
                            resetsAt: now.addingTimeInterval(1800),
                            resetDescription: nil)),
                    NamedRateWindow(
                        id: "codex-other-limit",
                        title: "Other Codex limit",
                        window: RateWindow(
                            usedPercent: 30,
                            windowMinutes: 1440,
                            resetsAt: now.addingTimeInterval(3600),
                            resetDescription: nil)),
                ],
                updatedAt: now),
            provider: .codex)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        #expect(controller.menuCardModel(for: .codex)?.metrics.contains {
            $0.id == CodexAdditionalRateLimitMapper.sparkWindowID
        } == true)

        settings.codexSparkUsageVisible = false
        let hiddenModel = try #require(controller.menuCardModel(for: .codex))
        #expect(!hiddenModel.metrics.contains { $0.id == CodexAdditionalRateLimitMapper.sparkWindowID })
        #expect(hiddenModel.metrics.contains { $0.id == "codex-other-limit" })
    }
}
