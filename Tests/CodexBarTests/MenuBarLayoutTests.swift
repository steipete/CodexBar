import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MenuBarLayoutTests {
    private struct UnnormalizedLayout: Encodable {
        let lines: [[MenuBarLayoutToken]]
    }

    @Test
    func `every token codable round trips`() throws {
        let layout = MenuBarLayout(lines: [
            [
                .icon,
                .providerName,
                .accountLabel,
                .percent(window: .session),
                .percent(window: .weekly),
                .percent(window: .automatic),
                .usageBar,
            ],
            [
                .resetCountdown,
                .resetAbsolute,
                .runsOut,
                .costToday,
                .cost30d,
                .separatorDot,
                .space,
            ],
        ])

        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(MenuBarLayout.self, from: data)

        #expect(decoded == layout)
    }

    @Test
    func `decoding normalizes empty and extra lines`() throws {
        let emptyData = try JSONEncoder().encode(UnnormalizedLayout(lines: []))
        #expect(try JSONDecoder().decode(MenuBarLayout.self, from: emptyData) == .defaultLayout)

        let extraData = try JSONEncoder().encode(UnnormalizedLayout(lines: [
            [],
            [.icon],
            [.providerName],
            [.accountLabel],
        ]))
        #expect(try JSONDecoder().decode(MenuBarLayout.self, from: extraData) == MenuBarLayout(lines: [
            [.icon],
            [.providerName],
        ]))

        let trailingEmptyData = try JSONEncoder().encode(UnnormalizedLayout(lines: [[.icon], []]))
        #expect(try JSONDecoder().decode(MenuBarLayout.self, from: trailingEmptyData).lines == [[.icon], []])
    }

    @Test
    func `semantic windows map Kimi weekly and short cadence lanes`() {
        let primary = RateWindow(usedPercent: 25, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let secondary = RateWindow(usedPercent: 50, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
        let windows = MenuBarLayoutSemanticWindowResolver.windows(
            provider: .kimi,
            snapshot: UsageSnapshot(primary: primary, secondary: secondary, updatedAt: Date()))

        #expect(windows.session == secondary)
        #expect(windows.weekly == primary)
    }

    @Test
    func `semantic windows leave unsupported lanes missing`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())
        let windows = MenuBarLayoutSemanticWindowResolver.windows(
            provider: .zai,
            snapshot: snapshot)

        #expect(windows.session == nil)
        #expect(windows.weekly == nil)
    }

    @Test
    func `cost today resolves the current calendar day aggregate`() {
        let now = Date(timeIntervalSince1970: 1_752_768_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: 99,
            last30DaysTokens: nil,
            last30DaysCostUSD: 9,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2025-07-16",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: nil,
                    costUSD: 6.25,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
                CostUsageDailyReport.Entry(
                    date: "2025-07-17",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: nil,
                    costUSD: 2.75,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: now)

        #expect(MenuBarLayoutCostResolver.todayCostUSD(
            snapshot: snapshot,
            now: now,
            calendar: calendar) == 2.75)
    }

    @Test
    func `migration maps every legacy style mode metric and reset combination`() {
        var visited = 0
        for style in MenuBarIconStyle.allCases {
            for mode in MenuBarDisplayMode.allCases {
                for metric in MenuBarMetricPreference.allCases {
                    for resetStyle in [ResetTimeDisplayStyle.countdown, .absolute] {
                        let resolution = MenuBarLayoutResolution.legacy(
                            iconStyle: style,
                            displayMode: mode,
                            metricPreference: metric,
                            resetTimeDisplayStyle: resetStyle)
                        let layout = resolution.layout
                        #expect((1...2).contains(layout.lines.count))
                        #expect(layout.lines.allSatisfy { !$0.isEmpty })
                        #expect(resolution.legacySettings == MenuBarLayoutResolution.LegacySettings(
                            iconStyle: style,
                            displayMode: mode,
                            metricPreference: metric,
                            resetTimeDisplayStyle: resetStyle))
                        #expect(resolution.usesLegacyRendering)
                        visited += 1
                    }
                }
            }
        }

        #expect(visited == MenuBarIconStyle.allCases.count * MenuBarDisplayMode.allCases.count
            * MenuBarMetricPreference.allCases.count * 2)
    }

    @Test
    func `migration preserves combined and reset intent`() {
        let combinedLayout = MenuBarLayout(lines: [
            [
                .icon,
                .percent(window: .session),
                .separatorDot,
                .percent(window: .weekly),
            ],
        ])
        #expect(MenuBarLayout.migrated(
            iconStyle: .iconAndPercent,
            displayMode: .percent,
            metricPreference: .primaryAndSecondary,
            resetTimeDisplayStyle: .countdown) == combinedLayout)
        #expect(MenuBarLayout.migrated(
            iconStyle: .iconAndPercent,
            displayMode: .resetTime,
            metricPreference: .automatic,
            resetTimeDisplayStyle: .absolute) == MenuBarLayout(lines: [[.icon, .resetAbsolute]]))
    }

    @Test
    func `migration preserves Kimi primary and secondary lane identity`() {
        #expect(MenuBarLayout.migrated(
            iconStyle: .iconAndPercent,
            displayMode: .percent,
            metricPreference: .primary,
            resetTimeDisplayStyle: .countdown,
            provider: .kimi) == MenuBarLayout(lines: [[.icon, .percent(window: .weekly)]]))
        #expect(MenuBarLayout.migrated(
            iconStyle: .iconAndPercent,
            displayMode: .percent,
            metricPreference: .secondary,
            resetTimeDisplayStyle: .countdown,
            provider: .kimi) == MenuBarLayout(lines: [[.icon, .percent(window: .session)]]))
    }

    @Test
    @MainActor
    func `global editing seeds the representative provider legacy layout`() throws {
        let settings = testSettingsStore(suiteName: "MenuBarLayoutTests-global-editor-migration")
        settings.setMenuBarMetricPreference(.primary, for: .kimi)
        let expected = MenuBarLayout(lines: [[.icon, .percent(window: .weekly)]])

        #expect(!settings.hasStoredMenuBarLayout)
        #expect(settings.menuBarLayoutForGlobalEditing(representativeProvider: .kimi) == expected)

        let stored = try #require(MenuBarLayoutPreset.iconOnly.layout)
        settings.setMenuBarLayout(stored, for: nil)
        #expect(settings.menuBarLayoutForGlobalEditing(representativeProvider: .kimi) == stored)
    }

    @Test
    @MainActor
    func `size and gap changes activate the edited layout`() throws {
        let globalSettings = testSettingsStore(suiteName: "MenuBarLayoutTests-size-activation")
        let globalLayout = try #require(MenuBarLayoutPreset.compactStacked.layout)
        MenuBarLayoutEditorPersistence.setSize(
            .small,
            activating: globalLayout,
            for: nil,
            settings: globalSettings)

        #expect(globalSettings.menuBarLayoutSize == .small)
        #expect(globalSettings.hasStoredMenuBarLayout)
        #expect(globalSettings.menuBarLayout == globalLayout)

        let providerSettings = testSettingsStore(suiteName: "MenuBarLayoutTests-gap-activation")
        let providerLayout = try #require(MenuBarLayoutPreset.percentAndReset.layout)
        MenuBarLayoutEditorPersistence.setGap(
            .tight,
            activating: providerLayout,
            for: .kimi,
            settings: providerSettings)

        #expect(providerSettings.menuBarLayoutGap == .tight)
        #expect(providerSettings.menuBarLayoutOverrides[.kimi] == providerLayout)
    }

    @Test
    @MainActor
    func `provider override and display options persist across reload`() throws {
        let suite = "MenuBarLayoutTests-provider-override"
        let settings = testSettingsStore(suiteName: suite)
        let global = try #require(MenuBarLayoutPreset.iconOnly.layout)
        let provider = try #require(MenuBarLayoutPreset.compactStacked.layout)

        settings.setMenuBarLayout(global, for: nil)
        settings.setMenuBarLayout(provider, for: .claude)
        settings.menuBarLayoutSize = .small
        settings.menuBarLayoutGap = .tight

        #expect(settings.menuBarLayout(for: .codex) == global)
        #expect(settings.menuBarLayout(for: .claude) == provider)
        #expect(!settings.menuBarLayoutResolution(for: .codex).usesLegacyRendering)

        let reloaded = Self.reloadSettingsStore(settings)
        #expect(reloaded.menuBarLayout(for: .codex) == global)
        #expect(reloaded.menuBarLayout(for: .claude) == provider)
        #expect(reloaded.menuBarLayoutSize == .small)
        #expect(reloaded.menuBarLayoutGap == .tight)

        reloaded.removeMenuBarLayoutOverride(for: .claude)
        let afterRemoval = Self.reloadSettingsStore(reloaded)
        #expect(afterRemoval.menuBarLayoutOverrides[.claude] == nil)
        #expect(afterRemoval.menuBarLayout(for: .claude) == global)
    }

    @Test
    func `preset application matches and manual edit becomes custom`() throws {
        let preset = MenuBarLayoutPreset.percentAndReset
        let layout = try #require(preset.layout)
        #expect(MenuBarLayoutPreset.matching(layout) == preset)

        let edited = MenuBarLayout(lines: [[.icon, .providerName, .percent(window: .automatic)]])
        #expect(MenuBarLayoutPreset.matching(edited) == .custom)
    }

    @MainActor
    private static func reloadSettingsStore(_ settings: SettingsStore) -> SettingsStore {
        SettingsStore(
            userDefaults: settings.userDefaults,
            configStore: settings.configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
    }
}
