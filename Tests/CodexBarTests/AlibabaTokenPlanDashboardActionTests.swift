import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct AlibabaTokenPlanDashboardActionTests {
    @Test
    func `dashboard action follows selected region`() {
        let settings = testSettingsStore(suiteName: "AlibabaTokenPlanDashboardActionTests")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.alibabaTokenPlanAPIRegion = .chinaMainland

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        withStatusItemControllerForTesting(store: store, settings: settings, fetcher: fetcher) { controller in
            #expect(controller.dashboardURL(for: .alibabatokenplan) ==
                AlibabaTokenPlanAPIRegion.chinaMainland.dashboardURL)
        }
    }
}
