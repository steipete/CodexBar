import CodexBarCore
import Testing
@testable import CodexBar

#if canImport(JavaScriptCore)
struct UserPluginQuotaPresentationTests {
    @MainActor
    @Test
    func `current selection retains a plugin even before its first snapshot`() throws {
        let plugin = try #require(ProviderInstanceID(rawValue: "fixture-meter"))
        let selected = StatusItemController.resolvedSwitcherProviderID(
            providerIDs: [.codex, plugin], selectedProviderID: plugin, fallbackProviderID: .codex)
        #expect(UnifiedIconContext.currentSelectionProvider(selected: selected, enabled: [.codex, plugin]) == plugin)
        #expect(UnifiedIconContext.currentSelectionProvider(selected: plugin, enabled: [.codex]) == nil)
    }

    @MainActor
    @Test
    func `plugin selection shares the six provider budget`() throws {
        let settings = testSettingsStore(suiteName: "plugin-overview-limit", userDefaults: InMemoryUserDefaults())
        let plugin = try #require(ProviderInstanceID(rawValue: "fixture-meter"))
        let active: [ProviderInstanceID] = [.codex, .claude, .cursor, .warp, .gemini, .opencode, plugin]
        #expect(settings.setMergedOverviewProviderSelection(
            provider: plugin, isSelected: true, activeProviders: active) == Array(active.prefix(6)))
        _ = settings.setMergedOverviewProviderSelection(provider: .claude, isSelected: false, activeProviders: active)
        let selected = settings.setMergedOverviewProviderSelection(
            provider: plugin, isSelected: true, activeProviders: active)
        #expect(selected == [.codex, .cursor, .warp, .gemini, .opencode, plugin])
        #expect(settings.userDefaults.stringArray(forKey: "mergedOverviewSelectedProviders") == selected
            .map(\.rawValue))
        #expect(settings.resolvedMergedOverviewProviders(activeProviders: active) == selected)
    }

    @Test
    func `plugin switcher prefers reported weekly windows then primary usage`() {
        func snapshot(
            _ primary: Double?, _ secondary: Double?, _ tertiary: Double?, weekly: Bool = false) -> UsageSnapshot
        {
            func window(_ percent: Double?) -> RateWindow? {
                percent.map { RateWindow(usedPercent: $0, windowMinutes: nil, resetsAt: nil, resetDescription: nil) }
            }
            return UsageSnapshot(
                primary: window(primary),
                secondary: secondary.map {
                    RateWindow(
                        usedPercent: $0,
                        windowMinutes: weekly ? 10080 : nil,
                        resetsAt: nil,
                        resetDescription: nil)
                },
                tertiary: window(tertiary),
                updatedAt: .distantPast)
        }
        #expect(StatusItemController.pluginSwitcherMetricPercent(
            snapshot: snapshot(20, 65, 90, weekly: true), showUsed: false) == 35)
        #expect(StatusItemController.pluginSwitcherMetricPercent(
            snapshot: snapshot(20, 65, 90, weekly: true), showUsed: true) == 65)
        #expect(StatusItemController.pluginSwitcherMetricPercent(
            snapshot: snapshot(20, 65, 90), showUsed: false) == 80)
        #expect(StatusItemController.pluginSwitcherMetricPercent(
            snapshot: snapshot(nil, nil, 90), showUsed: false) == 10)
        let extraWindows = [
            NamedRateWindow(
                id: "weekly",
                title: "Weekly",
                window: RateWindow(usedPercent: 80, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)),
            NamedRateWindow(
                id: "unknown",
                title: "Unknown",
                window: RateWindow(usedPercent: 100, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
                usageKnown: false),
        ]
        #expect(StatusItemController.pluginSwitcherMetricPercent(
            snapshot: UsageSnapshot(
                primary: nil, secondary: nil, extraRateWindows: extraWindows, updatedAt: .distantPast),
            showUsed: false) == 20)
        #expect(StatusItemController.pluginSwitcherMetricPercent(snapshot: nil, showUsed: false) == nil)
        #expect(StatusItemController.pluginSwitcherMetricPercent(
            snapshot: snapshot(nil, nil, nil), showUsed: true) == nil)
    }

    @Test
    func `remaining mode aligns plugin label and bar`() {
        let presentation = UserPluginQuotaPresentation.make(usedPercent: 4, showUsed: false)

        #expect(presentation.percent == 96)
        #expect(presentation.text == "96% left")
    }

    @Test
    func `used mode aligns plugin label and bar`() {
        let presentation = UserPluginQuotaPresentation.make(usedPercent: 4, showUsed: true)

        #expect(presentation.percent == 4)
        #expect(presentation.text == "4% used")
    }

    @Test
    func `plugin percentage is clamped before presentation`() {
        #expect(UserPluginQuotaPresentation.make(usedPercent: -5, showUsed: true).percent == 0)
        #expect(UserPluginQuotaPresentation.make(usedPercent: 105, showUsed: false).percent == 0)
    }
}
#endif
