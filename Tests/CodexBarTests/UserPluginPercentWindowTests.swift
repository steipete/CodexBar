import CodexBarCore
import Foundation
import Observation
import Testing
@testable import CodexBar

struct UserPluginPercentWindowTests {
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
        let global = MenuBarLayout(lines: [[.balance]])
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
