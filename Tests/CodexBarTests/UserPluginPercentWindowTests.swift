import CodexBarCore
import Foundation
import Observation
import Testing
@testable import CodexBar

struct UserPluginPercentWindowTests {
    @Test(arguments: [false, true], [false, true])
    @MainActor
    func `icon observation follows the saved monthly window on data updates`(namedExtra: Bool, showUsed: Bool) throws {
        let settings = testSettingsStore(suiteName: "plugin-icon-window", userDefaults: InMemoryUserDefaults())
        settings.usageBarsShowUsed = showUsed
        settings.menuBarShowsBrandIconWithPercent = true
        let plugin = try #require(ProviderInstanceID(rawValue: "example-pool"))
        settings.setMenuBarLayout(
            MenuBarLayout(lines: [[namedExtra ? .extraPercent(id: "monthly") : .lanePercent(lane: .tertiary)]]),
            forInstanceID: plugin)

        func signature(monthlyPercent: Double, weeklyPercent: Double = 0) -> String {
            let monthly = RateWindow(
                usedPercent: monthlyPercent, windowMinutes: 43200, resetsAt: nil, resetDescription: nil)
            let snapshot = UsageSnapshot(
                primary: Self.pooledSnapshot.primary,
                secondary: RateWindow(
                    usedPercent: weeklyPercent, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
                tertiary: namedExtra ? nil : monthly,
                extraRateWindows: namedExtra ? [NamedRateWindow(id: "monthly", title: "Monthly", window: monthly)] :
                    nil,
                updatedAt: .distantPast)
            return StatusItemController.pluginStoreIconObservationSignature(
                for: plugin, snapshot: snapshot, settings: settings, hasError: false, sourceHash: "fixture")
        }

        let before = signature(monthlyPercent: 76.9)
        let after = signature(monthlyPercent: 80)
        #expect(before != after)
        #expect(after == signature(monthlyPercent: 80, weeklyPercent: 5))
        settings.menuBarShowsBrandIconWithPercent = false
        #expect(signature(monthlyPercent: 80) != signature(monthlyPercent: 80, weeklyPercent: 5))
    }

    @Test(arguments: [false, true])
    @MainActor
    func `icon observation keeps automatic fallback when a saved window is unavailable`(showUsed: Bool) throws {
        let settings = testSettingsStore(suiteName: "plugin-icon-fallback", userDefaults: InMemoryUserDefaults())
        settings.usageBarsShowUsed = showUsed
        settings.menuBarShowsBrandIconWithPercent = true
        let plugin = try #require(ProviderInstanceID(rawValue: "example-pool"))
        let snapshot = Self.pooledSnapshot
        let automatic = StatusItemController.pluginStoreIconObservationSignature(
            for: plugin, snapshot: snapshot, settings: settings, hasError: false, sourceHash: "fixture")
        settings.setMenuBarLayout(MenuBarLayout(lines: [[.extraPercent(id: "missing")]]), forInstanceID: plugin)
        let fallback = StatusItemController.pluginStoreIconObservationSignature(
            for: plugin, snapshot: snapshot, settings: settings, hasError: false, sourceHash: "fixture")
        #expect(fallback == automatic)
    }

    @Test
    func `automatic ignores synthetic placeholder windows`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 100,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil,
                isSyntheticPlaceholder: true),
            secondary: RateWindow(usedPercent: 42, windowMinutes: 1440, resetsAt: nil, resetDescription: nil),
            updatedAt: .distantPast)
        #expect(StatusItemController.pluginSwitcherMetricPercent(snapshot: snapshot, showUsed: true) == 42)
    }

    @Test
    @MainActor
    func `unset plugin layouts inherit global while saved automatic remains exact`() throws {
        let defaults = InMemoryUserDefaults()
        let settings = testSettingsStore(suiteName: "plugin-layout-inheritance", userDefaults: defaults)
        let plugin = try #require(ProviderInstanceID(rawValue: "layout-example"))
        let global = MenuBarLayout(lines: [[.icon, .percent(window: .weekly), .separatorDot, .resetCountdown]])
        settings.setMenuBarLayout(global, for: nil)
        #expect(settings.menuBarLayout(forPlugin: plugin) == global)
        let shippedChoice = MenuBarLayout(lines: [[.percent(window: .automatic)]])
        settings.setMenuBarLayout(shippedChoice, forInstanceID: plugin)
        let reloaded = testSettingsStore(suiteName: "plugin-layout-inheritance-reloaded", userDefaults: defaults)
        #expect(reloaded.menuBarLayout(forPlugin: plugin) == shippedChoice)
        reloaded.removeMenuBarLayoutOverride(forInstanceID: plugin)
        #expect(reloaded.menuBarLayout(forPlugin: plugin) == global)
    }

    @Test
    func `monthly selection shows 77 percent after the weekly reset`() throws {
        let snapshot = Self.pooledSnapshot
        let percent = try #require(StatusItemController.pluginSwitcherMetricPercent(
            snapshot: snapshot, showUsed: true, preference: .tertiary))
        #expect(UsageFormatter.percentString(percent) == "77%")
        let remaining = try #require(StatusItemController.pluginSwitcherMetricPercent(
            snapshot: snapshot, showUsed: false, preference: .tertiary))
        #expect(UsageFormatter.percentString(remaining) == "23%")
        #expect(StatusItemController.pluginSwitcherMetricPercent(snapshot: snapshot, showUsed: true) == 0)
        #expect(StatusItemController.pluginSwitcherMetricPercent(
            snapshot: snapshot, showUsed: true, preference: .session) == 10)
        #expect(StatusItemController.pluginSwitcherMetricPercent(
            snapshot: snapshot, showUsed: true, preference: .weekly) == 0)
        let lanes = StatusItemController.pluginMeterPercents(snapshot: snapshot, showUsed: true)
        #expect(lanes.primary == 10)
        #expect(lanes.secondary == 0)
    }

    @Test
    func `named extra selection uses known usage and missing windows fall back to automatic`() throws {
        let monthly = try #require(Self.pooledSnapshot.tertiary)
        let snapshot = UsageSnapshot(
            primary: Self.pooledSnapshot.primary,
            secondary: Self.pooledSnapshot.secondary,
            extraRateWindows: [
                NamedRateWindow(
                    id: "monthly", title: "Monthly pool", window: monthly),
                NamedRateWindow(
                    id: "unknown", title: "Reset only", window: monthly, usageKnown: false),
            ],
            updatedAt: .distantPast)
        #expect(StatusItemController.pluginSwitcherMetricPercent(
            snapshot: snapshot, showUsed: true, preference: .extra(id: "monthly")) == 76.9)
        #expect(StatusItemController.pluginSwitcherMetricPercent(
            snapshot: snapshot, showUsed: true, preference: .extra(id: "unknown")) == 0)
        #expect(StatusItemController.pluginSwitcherMetricPercent(
            snapshot: snapshot, showUsed: true, preference: .extra(id: "missing")) == 0)
        #expect(StatusItemController.pluginSwitcherMetricPercent(
            snapshot: snapshot, showUsed: false, preference: .tertiary) == 100)
        #expect(StatusItemController.pluginSwitcherMetricPercent(
            snapshot: nil, showUsed: true, preference: .tertiary) == nil)
        #expect(MenuBarPercentWindowPreference.extra(id: "monthly")
            .label(for: nil, snapshot: snapshot) == "Monthly pool")
    }

    @Test
    @MainActor
    func `plugin picker persists existing layout tokens independently of global and other provider layouts`() throws {
        let defaults = InMemoryUserDefaults()
        let settings = testSettingsStore(suiteName: "plugin-window", userDefaults: defaults)
        let plugin = try #require(ProviderInstanceID(rawValue: "example-pool"))
        let other = try #require(ProviderInstanceID(rawValue: "other-pool"))
        let global = MenuBarLayout(lines: [[.icon, .percent(window: .automatic), .balance]])
        settings.setMenuBarLayout(global, for: nil)
        let view = ProviderMenuBarPercentWindowSettingsView(
            instanceID: plugin, settings: settings, snapshot: Self.pooledSnapshot)
        let picker = ProviderMenuBarPercentWindowPicker(
            provider: nil, iconStyle: .bars, layout: view.layoutBinding, snapshot: Self.pooledSnapshot)
        #expect(picker.selectionBinding.wrappedValue == .automatic)
        #expect(picker.available == [.automatic, .session, .weekly, .tertiary])
        #expect(MenuBarPercentWindowPreference.tertiary.label(for: nil, snapshot: Self.pooledSnapshot) == "Monthly")
        #expect(MenuBarPercentWindowPreference.session.label(for: nil) == L("Primary"))
        #expect(MenuBarPercentWindowPreference.weekly.label(for: nil) == L("Secondary"))
        #expect(MenuBarPercentWindowPreference.tertiary.label(for: nil) == L("Tertiary"))
        for choice in picker.available {
            picker.selectionBinding.wrappedValue = choice
            let reloaded = testSettingsStore(suiteName: "plugin-window-reloaded", userDefaults: defaults)
            #expect(MenuBarPercentWindowPreference.current(in: reloaded.menuBarLayout(forPlugin: plugin)) == choice)
            #expect(reloaded.menuBarLayout(for: .codex) == global)
            #expect(MenuBarPercentWindowPreference.current(in: reloaded.menuBarLayout(forPlugin: other)) == .automatic)
        }
        let extra = MenuBarPercentWindowPreference.extra(id: "monthly")
        let namedSnapshot = try UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [NamedRateWindow(
                id: "monthly", title: "Monthly pool", window: #require(Self.pooledSnapshot.tertiary))],
            updatedAt: .distantPast)
        let namedPicker = ProviderMenuBarPercentWindowPicker(
            provider: nil, iconStyle: .bars, layout: view.layoutBinding, snapshot: namedSnapshot)
        #expect(namedPicker.available.contains(extra))
        namedPicker.selectionBinding.wrappedValue = extra
        let reloaded = testSettingsStore(suiteName: "plugin-extra-reloaded", userDefaults: defaults)
        let absent = ProviderMenuBarPercentWindowPicker(
            provider: nil,
            iconStyle: .bars,
            layout: ProviderMenuBarPercentWindowSettingsView(instanceID: plugin, settings: reloaded).layoutBinding)
        #expect(absent.selectionBinding.wrappedValue == extra)
        #expect(extra.label(for: nil) == "monthly")
        absent.selectionBinding.wrappedValue = .automatic
        #expect(MenuBarPercentWindowPreference.current(in: reloaded.menuBarLayout(forPlugin: plugin)) == .automatic)
        #expect(reloaded.menuBarIconStyle == settings.menuBarIconStyle)
        absent.selectionBinding.wrappedValue = .tertiary
        reloaded.removeMenuBarLayoutOverride(forInstanceID: plugin)
        let removed = testSettingsStore(suiteName: "plugin-window-removed", userDefaults: defaults)
        #expect(MenuBarPercentWindowPreference.current(in: removed.menuBarLayout(forPlugin: plugin)) == .automatic)
    }

    @Test
    @MainActor
    func `display selection refreshes menus without changing snapshot or hook duration metadata`() async throws {
        let settings = testSettingsStore(suiteName: "plugin-window-metadata", userDefaults: InMemoryUserDefaults())
        let plugin = try #require(ProviderInstanceID(rawValue: "example-pool"))
        let snapshot = Self.pooledSnapshot
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let originalJSON = try encoder.encode(snapshot)
        let originalHook = HookEvent.usageUpdated(
            provider: plugin.rawValue, snapshot: snapshot, account: nil, timestamp: .distantPast)
        let revision = settings.configRevision
        let view = ProviderMenuBarPercentWindowSettingsView(instanceID: plugin, settings: settings, snapshot: snapshot)
        let picker = ProviderMenuBarPercentWindowPicker(
            provider: nil, iconStyle: .bars, layout: view.layoutBinding, snapshot: snapshot)
        await confirmation { changed in
            withObservationTracking {
                _ = settings.menuObservationToken
            } onChange: {
                changed()
            }
            picker.selectionBinding.wrappedValue = .tertiary
        }
        #expect(settings.configRevision == revision)
        #expect(try StatusItemController.pluginSwitcherMetricPercent(
            snapshot: snapshot,
            showUsed: true,
            preference: #require(picker.selectionBinding.wrappedValue)) == 76.9)
        #expect(try encoder.encode(snapshot) == originalJSON)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: encoder.encode(snapshot))
        #expect(decoded.primary?.windowMinutes == 300)
        #expect(decoded.secondary?.windowMinutes == 10080)
        #expect(decoded.tertiary?.windowMinutes == 43200)
        let hook = HookEvent.usageUpdated(
            provider: plugin.rawValue, snapshot: snapshot, account: nil, timestamp: .distantPast)
        #expect(try hook.jsonPayload() == originalHook.jsonPayload())
        #expect(hook.environmentVariables() == originalHook.environmentVariables())
        #expect(hook.environmentVariables()["CODEXBAR_WINDOW_MINUTES"] == "300")
        #expect(hook.environmentVariables()["CODEXBAR_SECONDARY_WINDOW_MINUTES"] == "10080")
        #expect(hook.resetAt == snapshot.primary?.resetsAt)
        #expect(hook.secondaryResetAt == snapshot.secondary?.resetsAt)
    }

    private static var pooledSnapshot: UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 10,
                windowMinutes: 300,
                resetsAt: Date(timeIntervalSince1970: 1_800_000_000),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 0,
                windowMinutes: 10080,
                resetsAt: Date(timeIntervalSince1970: 1_800_500_000),
                resetDescription: nil),
            tertiary: RateWindow(
                usedPercent: 76.9,
                windowMinutes: 43200,
                resetsAt: Date(timeIntervalSince1970: 1_802_500_000),
                resetDescription: nil,
                title: "Monthly"),
            updatedAt: .distantPast)
    }
}
