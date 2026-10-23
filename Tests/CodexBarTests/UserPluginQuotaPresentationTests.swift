import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

#if canImport(JavaScriptCore)
struct UserPluginQuotaPresentationTests {
    @Test
    func `plugin meters preserve primary and secondary windows independently of the switcher metric`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 65, windowMinutes: 43200, resetsAt: nil, resetDescription: nil),
            updatedAt: .distantPast)
        for showUsed in [false, true] {
            let lanes = StatusItemController.pluginMeterPercents(snapshot: snapshot, showUsed: showUsed)
            #expect(lanes.primary == (showUsed ? 20 : 80))
            #expect(lanes.secondary == (showUsed ? 65 : 35))
        }
        let missing = StatusItemController.pluginMeterPercents(snapshot: nil, showUsed: false)
        #expect(missing.primary == nil)
        #expect(missing.secondary == nil)
        let extraOnly = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: RateWindow(usedPercent: 75, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: .distantPast)
        let fallback = StatusItemController.pluginMeterPercents(snapshot: extraOnly, showUsed: false)
        #expect(fallback.primary == 25)
        #expect(fallback.secondary == nil)
        let overage = UsageSnapshot(
            primary: RateWindow(usedPercent: 150, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 250, windowMinutes: 43200, resetsAt: nil, resetDescription: nil),
            updatedAt: .distantPast)
        let capped = StatusItemController.pluginMeterPercents(snapshot: overage, showUsed: true)
        #expect(capped.primary == 100)
        #expect(capped.secondary == 100)
    }

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
        let presentation = UserPluginQuotaPresentation.make(
            title: "Primary",
            window: RateWindow(usedPercent: 4, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            showUsed: false,
            resetStyle: .countdown)

        #expect(presentation.percent == 96)
        #expect(presentation.text == "96% left")
    }

    @Test
    func `used mode aligns plugin label and bar`() {
        let presentation = UserPluginQuotaPresentation.make(
            title: "Primary",
            window: RateWindow(usedPercent: 4, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            showUsed: true,
            resetStyle: .countdown)

        #expect(presentation.percent == 4)
        #expect(presentation.text == "4% used")
    }

    @Test
    func `plugin percentage is clamped before presentation`() {
        #expect(UserPluginQuotaPresentation.make(
            title: "Primary",
            window: RateWindow(usedPercent: -5, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            showUsed: true,
            resetStyle: .countdown).percent == 0)
        #expect(UserPluginQuotaPresentation.make(
            title: "Primary",
            window: RateWindow(usedPercent: 105, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            showUsed: false,
            resetStyle: .countdown).percent == 0)
    }

    @Test
    func `plugin cards use custom titles and the shared reset formatter`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let window = RateWindow(
            usedPercent: 25,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(3600),
            resetDescription: nil,
            title: "Requests")
        for style in [ResetTimeDisplayStyle.countdown, .absolute] {
            let presentation = UserPluginQuotaPresentation.make(
                title: "Primary", window: window, showUsed: true, resetStyle: style, now: now)
            #expect(presentation.title == "Requests")
            #expect(presentation.resetText == UsageFormatter.resetLine(for: window, style: style, now: now))
        }
        let fallback = UserPluginQuotaPresentation.make(
            title: "Secondary",
            window: RateWindow(
                usedPercent: 50,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "tomorrow"),
            showUsed: false,
            resetStyle: .countdown,
            now: now)
        #expect(fallback.title == "Secondary")
        #expect(fallback.resetText == "Resets tomorrow")
        #expect(fallback.percent == 50)
    }

    @MainActor
    @Test
    func `plugin height fingerprint includes rendered titles and reset text`() {
        let first = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "tomorrow",
                title: "Requests"),
            secondary: nil,
            updatedAt: .distantPast)
        let second = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "tomorrow",
                title: "A longer allowance title"),
            secondary: nil,
            updatedAt: .distantPast)
        let third = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "on Monday",
                title: "Requests"),
            secondary: nil,
            updatedAt: .distantPast)
        let fingerprint = UserPluginMenuCardView.fingerprint(snapshot: first, error: nil, resetStyle: .countdown)
        #expect(fingerprint != UserPluginMenuCardView.fingerprint(snapshot: second, error: nil, resetStyle: .countdown))
        #expect(fingerprint != UserPluginMenuCardView.fingerprint(snapshot: third, error: nil, resetStyle: .countdown))
    }
}
#endif
