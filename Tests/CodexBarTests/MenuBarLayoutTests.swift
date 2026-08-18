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
                .lanePercent(lane: .primary),
                .lanePercent(lane: .secondary),
                .lanePercent(lane: .tertiary),
                .pace(window: .session),
                .pace(window: .weekly),
                .pace(window: .automatic),
                .usageBar,
            ],
            [
                .resetCountdown,
                .resetAbsolute,
                .runsOut,
                .runsOutCompact,
                .balance,
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
    func `run out token discriminators stay stable`() throws {
        let labeled = try JSONEncoder().encode(MenuBarLayoutToken.runsOut)
        let compact = try JSONEncoder().encode(MenuBarLayoutToken.runsOutCompact)

        #expect(String(bytes: labeled, encoding: .utf8) == #"{"runsOut":{}}"#)
        #expect(String(bytes: compact, encoding: .utf8) == #"{"runsOutCompact":{}}"#)
        #expect(try JSONDecoder().decode(MenuBarLayoutToken.self, from: labeled) == .runsOut)
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
    func `semantic windows map Notion rolling and monthly lanes`() {
        let rolling = RateWindow(usedPercent: 25, windowMinutes: 360, resetsAt: nil, resetDescription: nil)
        let monthly = RateWindow(
            usedPercent: 50,
            windowMinutes: ProviderPaceCapability.monthlyWindowSentinelMinutes,
            resetsAt: nil,
            resetDescription: nil)
        let windows = MenuBarLayoutSemanticWindowResolver.windows(
            provider: .notion,
            snapshot: UsageSnapshot(primary: rolling, secondary: monthly, updatedAt: Date()))

        #expect(windows.session == rolling)
        #expect(windows.weekly == monthly)
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
    func `lane percent tokens map to older-readable percent tokens`() {
        let layout = MenuBarLayout(lines: [[
            .icon,
            .lanePercent(lane: .primary),
            .lanePercent(lane: .secondary),
            .lanePercent(lane: .tertiary),
            .separatorDot,
        ]])

        #expect(layout.legacyCompatible() == MenuBarLayout(lines: [[
            .icon,
            .percent(window: .session),
            .percent(window: .weekly),
            .percent(window: .automatic),
            .separatorDot,
        ]]))
        #expect(layout.legacyCompatible(for: .kimi) == MenuBarLayout(lines: [[
            .icon,
            .percent(window: .weekly),
            .percent(window: .session),
            .percent(window: .automatic),
            .separatorDot,
        ]]))
        #expect(layout.selectedLanes == Set(MenuBarLayoutLane.allCases))
        #expect(layout.legacyCompatible().selectedLanes.isEmpty)
    }

    @Test
    func `legacy layout JSON without lanePercent cannot decode current lane tokens`() throws {
        let current = try JSONEncoder().encode(MenuBarLayout(lines: [[
            .icon,
            .lanePercent(lane: .secondary),
        ]]))

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PreLanePercentMenuBarLayout.self, from: current)
        }
    }

    @Test
    func `Cursor lane tokens use the provider row labels`() {
        #expect(MenuBarLayoutToken.lanePercent(lane: .primary).editorLabel(provider: .cursor) == "Total %")
        #expect(MenuBarLayoutToken.lanePercent(lane: .secondary).editorLabel(provider: .cursor) == "Cursor %")
        #expect(MenuBarLayoutToken.lanePercent(lane: .tertiary).editorLabel(provider: .cursor) == "Third Party %")
    }

    @Test
    func `Amp lane tokens use snapshot presentation labels`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        #expect(MenuBarLayoutToken.lanePercent(lane: .primary)
            .editorLabel(provider: .amp, snapshot: snapshot) == "Other usage %")
        #expect(MenuBarLayoutToken.lanePercent(lane: .secondary)
            .editorLabel(provider: .amp, snapshot: snapshot) == "Orb usage %")
    }

    @Test
    func `direct lane tokens only expose provider supported metrics`() {
        #expect(MenuBarLayoutLane.available(for: nil).isEmpty)
        #expect(MenuBarLayoutLane.available(for: .mistral).isEmpty)
        #expect(MenuBarLayoutLane.available(for: .openrouter) == [.primary])
        #expect(MenuBarLayoutLane.available(for: .cursor) == [.primary, .secondary])

        let legacySnapshot = UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date())
        #expect(MenuBarLayoutLane.available(for: .cursor, snapshot: legacySnapshot) == [.primary, .secondary])

        let usageSnapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: RateWindow(usedPercent: 17, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())
        #expect(MenuBarLayoutLane.available(for: .cursor, snapshot: usageSnapshot) == [
            .primary,
            .secondary,
            .tertiary,
        ])
    }

    @Test
    func `scoped weekly window picks the most constrained active carve-out`() {
        let fable = NamedRateWindow(
            id: "claude-weekly-scoped-fable",
            title: "Fable only",
            window: RateWindow(usedPercent: 40, windowMinutes: 7 * 24 * 60, resetsAt: nil, resetDescription: nil))
        let other = NamedRateWindow(
            id: "claude-weekly-scoped-someothermodel",
            title: "Some other model only",
            window: RateWindow(usedPercent: 75, windowMinutes: 7 * 24 * 60, resetsAt: nil, resetDescription: nil))
        // A non-scoped extra window must be ignored even when it is more constrained.
        let routines = NamedRateWindow(
            id: "claude-routines",
            title: "Daily Routines",
            window: RateWindow(usedPercent: 90, windowMinutes: 7 * 24 * 60, resetsAt: nil, resetDescription: nil))
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [fable, other, routines],
            updatedAt: Date())

        let named = MenuBarLayoutSemanticWindowResolver.scopedWeeklyNamedWindow(snapshot: snapshot)

        #expect(named?.window.usedPercent == 75)
        // The most constrained window is a non-Fable model; its title must be carried so the
        // menu-bar token labels the correct model instead of assuming Fable.
        #expect(named?.title == "Some other model only")
    }

    @Test
    func `scoped weekly window is nil without a carve-out`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 55, windowMinutes: 7 * 24 * 60, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        #expect(MenuBarLayoutSemanticWindowResolver.scopedWeeklyNamedWindow(snapshot: snapshot) == nil)
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
    func `migration preserves OpenRouter automatic balance for every display mode`() {
        let expected = MenuBarLayout(lines: [[.icon, .balance]])

        for displayMode in MenuBarDisplayMode.allCases {
            #expect(MenuBarLayout.migrated(
                iconStyle: .iconAndPercent,
                displayMode: displayMode,
                metricPreference: .automatic,
                resetTimeDisplayStyle: .countdown,
                provider: .openrouter) == expected)
        }

        #expect(MenuBarLayout.migrated(
            iconStyle: .iconAndPercent,
            displayMode: .percent,
            metricPreference: .primary,
            resetTimeDisplayStyle: .countdown,
            provider: .openrouter) == MenuBarLayout(lines: [[.icon, .percent(window: .session)]]))
    }

    @Test
    @MainActor
    func `editing OpenRouter legacy automatic layout persists its balance`() {
        let settings = testSettingsStore(suiteName: "MenuBarLayoutTests-openrouter-editor-migration")
        settings.setMenuBarMetricPreference(.automatic, for: .openrouter)
        let migrated = settings.menuBarLayout(for: .openrouter)

        #expect(!settings.hasStoredMenuBarLayout)
        #expect(migrated == MenuBarLayout(lines: [[.icon, .balance]]))

        MenuBarLayoutEditorPersistence.setGap(
            .tight,
            activating: migrated,
            for: .openrouter,
            settings: settings)

        #expect(settings.menuBarLayoutOverrides[.openrouter] == migrated)
        #expect(settings.menuBarLayout(for: .openrouter) == migrated)
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
    @MainActor
    func `lane layouts dual-write an older-readable fallback`() throws {
        let settings = testSettingsStore(suiteName: "MenuBarLayoutTests-lane-downgrade")
        let global = MenuBarLayout(lines: [[.icon, .lanePercent(lane: .primary)]])
        let cursor = MenuBarLayout(lines: [[.icon, .lanePercent(lane: .secondary)]])
        let claude = try #require(MenuBarLayoutPreset.compactStacked.layout)

        settings.setMenuBarLayout(global, for: nil)
        settings.setMenuBarLayout(cursor, for: .cursor)
        settings.setMenuBarLayout(claude, for: .claude)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let currentGlobal = try #require(settings.userDefaults.data(forKey: MenuBarLayoutUserDefaultsKey.layoutCurrent))
        let legacyGlobal = try #require(settings.userDefaults.data(forKey: MenuBarLayoutUserDefaultsKey.layout))
        let currentOverrides = try #require(
            settings.userDefaults.data(forKey: MenuBarLayoutUserDefaultsKey.overridesCurrent))
        let legacyOverrides = try #require(settings.userDefaults.data(forKey: MenuBarLayoutUserDefaultsKey.overrides))

        #expect(try decoder.decode(MenuBarLayout.self, from: currentGlobal) == global)
        #expect(try decoder.decode(PreLanePercentMenuBarLayout.self, from: legacyGlobal) == PreLanePercentMenuBarLayout(
            lines: [[.icon, .percent(window: .session)]]))
        #expect(throws: DecodingError.self) {
            try decoder.decode(PreLanePercentMenuBarLayout.self, from: currentGlobal)
        }

        let currentMap = try decoder.decode([String: MenuBarLayout].self, from: currentOverrides)
        #expect(currentMap["cursor"] == cursor)
        #expect(currentMap["claude"] == claude)

        let legacyMap = try decoder.decode([String: PreLanePercentMenuBarLayout].self, from: legacyOverrides)
        let expectedClaudeLegacy = try decoder.decode(
            PreLanePercentMenuBarLayout.self,
            from: encoder.encode(claude))
        #expect(legacyMap["cursor"] == PreLanePercentMenuBarLayout(lines: [[.icon, .percent(window: .weekly)]]))
        #expect(legacyMap["claude"] == expectedClaudeLegacy)
        #expect(throws: DecodingError.self) {
            try decoder.decode([String: PreLanePercentMenuBarLayout].self, from: currentOverrides)
        }

        let reloaded = Self.reloadSettingsStore(settings)
        #expect(reloaded.menuBarLayout == global)
        #expect(reloaded.menuBarLayoutOverrides[.cursor] == cursor)
        #expect(reloaded.menuBarLayoutOverrides[.claude] == claude)
    }

    @Test
    @MainActor
    func `Kimi lane overrides dual-write reversed semantic windows`() throws {
        let settings = testSettingsStore(suiteName: "MenuBarLayoutTests-kimi-downgrade")
        let kimi = MenuBarLayout(lines: [[
            .icon,
            .lanePercent(lane: .primary),
            .lanePercent(lane: .secondary),
        ]])
        settings.setMenuBarLayout(kimi, for: .kimi)

        let legacyOverrides = try #require(settings.userDefaults.data(forKey: MenuBarLayoutUserDefaultsKey.overrides))
        let legacyMap = try JSONDecoder().decode([String: PreLanePercentMenuBarLayout].self, from: legacyOverrides)
        #expect(legacyMap["kimi"] == PreLanePercentMenuBarLayout(lines: [[
            .icon,
            .percent(window: .weekly),
            .percent(window: .session),
        ]]))

        let reloaded = Self.reloadSettingsStore(settings)
        #expect(reloaded.menuBarLayoutOverrides[.kimi] == kimi)
    }

    @Test
    @MainActor
    func `startup migrates pre-V2 direct-lane layouts into V2 and an older-readable fallback`() throws {
        let settings = testSettingsStore(suiteName: "MenuBarLayoutTests-pre-v2-startup")
        let global = MenuBarLayout(lines: [[.icon, .lanePercent(lane: .primary)]])
        let cursor = MenuBarLayout(lines: [[.icon, .lanePercent(lane: .secondary)]])
        let kimi = MenuBarLayout(lines: [[
            .icon,
            .lanePercent(lane: .primary),
            .lanePercent(lane: .secondary),
        ]])
        let encoder = JSONEncoder()
        try settings.userDefaults.set(encoder.encode(global), forKey: MenuBarLayoutUserDefaultsKey.layout)
        try settings.userDefaults.set(
            encoder.encode(["cursor": cursor, "kimi": kimi]),
            forKey: MenuBarLayoutUserDefaultsKey.overrides)
        settings.userDefaults.removeObject(forKey: MenuBarLayoutUserDefaultsKey.layoutCurrent)
        settings.userDefaults.removeObject(forKey: MenuBarLayoutUserDefaultsKey.overridesCurrent)

        let reloaded = Self.reloadSettingsStore(settings)
        #expect(reloaded.menuBarLayout == global)
        #expect(reloaded.menuBarLayoutOverrides[.cursor] == cursor)
        #expect(reloaded.menuBarLayoutOverrides[.kimi] == kimi)

        let decoder = JSONDecoder()
        let currentGlobal = try #require(reloaded.userDefaults.data(forKey: MenuBarLayoutUserDefaultsKey.layoutCurrent))
        let legacyGlobal = try #require(reloaded.userDefaults.data(forKey: MenuBarLayoutUserDefaultsKey.layout))
        #expect(try decoder.decode(MenuBarLayout.self, from: currentGlobal) == global)
        #expect(try decoder.decode(PreLanePercentMenuBarLayout.self, from: legacyGlobal) == PreLanePercentMenuBarLayout(
            lines: [[.icon, .percent(window: .session)]]))
        #expect(throws: DecodingError.self) {
            try decoder.decode(PreLanePercentMenuBarLayout.self, from: currentGlobal)
        }

        let currentOverrides = try decoder.decode(
            [String: MenuBarLayout].self,
            from: #require(reloaded.userDefaults.data(forKey: MenuBarLayoutUserDefaultsKey.overridesCurrent)))
        #expect(currentOverrides["cursor"] == cursor)
        #expect(currentOverrides["kimi"] == kimi)
        let legacyOverrides = try decoder.decode(
            [String: PreLanePercentMenuBarLayout].self,
            from: #require(reloaded.userDefaults.data(forKey: MenuBarLayoutUserDefaultsKey.overrides)))
        #expect(legacyOverrides["cursor"] == PreLanePercentMenuBarLayout(lines: [[.icon, .percent(window: .weekly)]]))
        #expect(legacyOverrides["kimi"] == PreLanePercentMenuBarLayout(lines: [[
            .icon,
            .percent(window: .weekly),
            .percent(window: .session),
        ]]))

        try Self.writeStartupMigrationProof(
            beforeKeys: ["menuBarLayout", "menuBarLayoutOverrides"],
            currentGlobal: currentGlobal,
            legacyGlobal: legacyGlobal,
            currentOverrides: #require(
                reloaded.userDefaults.data(forKey: MenuBarLayoutUserDefaultsKey.overridesCurrent)),
            legacyOverrides: #require(reloaded.userDefaults.data(forKey: MenuBarLayoutUserDefaultsKey.overrides)))
    }

    @Test
    @MainActor
    func `startup writes a missing fallback when only the V2 layout key exists`() throws {
        let settings = testSettingsStore(suiteName: "MenuBarLayoutTests-v2-only-startup")
        let current = MenuBarLayout(lines: [[.icon, .lanePercent(lane: .tertiary)]])
        settings.setMenuBarLayout(current, for: nil)
        settings.userDefaults.removeObject(forKey: MenuBarLayoutUserDefaultsKey.layout)

        let reloaded = Self.reloadSettingsStore(settings)
        #expect(reloaded.menuBarLayout == current)
        let legacyGlobal = try #require(reloaded.userDefaults.data(forKey: MenuBarLayoutUserDefaultsKey.layout))
        #expect(try JSONDecoder().decode(PreLanePercentMenuBarLayout.self, from: legacyGlobal)
            == PreLanePercentMenuBarLayout(lines: [[.icon, .percent(window: .automatic)]]))
    }

    @Test
    @MainActor
    func `lane layout load prefers a legacy blob edited by an older release`() throws {
        let settings = testSettingsStore(suiteName: "MenuBarLayoutTests-lane-downgrade-edit")
        let current = MenuBarLayout(lines: [[.icon, .lanePercent(lane: .primary)]])
        let edited = MenuBarLayout(lines: [[.icon, .percent(window: .weekly)]])
        settings.setMenuBarLayout(current, for: nil)
        try settings.userDefaults.set(
            JSONEncoder().encode(edited),
            forKey: MenuBarLayoutUserDefaultsKey.layout)

        let reloaded = Self.reloadSettingsStore(settings)
        #expect(reloaded.menuBarLayout == edited)
        let persistedCurrent = try JSONDecoder().decode(
            MenuBarLayout.self,
            from: #require(reloaded.userDefaults.data(forKey: MenuBarLayoutUserDefaultsKey.layoutCurrent)))
        let persistedLegacy = try JSONDecoder().decode(
            MenuBarLayout.self,
            from: #require(reloaded.userDefaults.data(forKey: MenuBarLayoutUserDefaultsKey.layout)))
        #expect(persistedCurrent == current)
        #expect(persistedLegacy == edited)
    }

    @Test
    @MainActor
    func `lane layout load keeps current lanes when the legacy blob is the fallback`() throws {
        let settings = testSettingsStore(suiteName: "MenuBarLayoutTests-lane-legacy-echo")
        let current = MenuBarLayout(lines: [[.icon, .lanePercent(lane: .secondary)]])
        settings.setMenuBarLayout(current, for: nil)
        let fallback = current.legacyCompatible()
        try settings.userDefaults.set(
            JSONEncoder().encode(fallback),
            forKey: MenuBarLayoutUserDefaultsKey.layout)

        let reloaded = Self.reloadSettingsStore(settings)
        #expect(reloaded.menuBarLayout == current)
    }

    @Test
    @MainActor
    func `lane override load prefers a legacy dictionary edited by an older release`() throws {
        let settings = testSettingsStore(suiteName: "MenuBarLayoutTests-lane-override-downgrade-edit")
        let cursor = MenuBarLayout(lines: [[.icon, .lanePercent(lane: .secondary)]])
        let claude = try #require(MenuBarLayoutPreset.compactStacked.layout)
        settings.setMenuBarLayout(cursor, for: .cursor)
        settings.setMenuBarLayout(claude, for: .claude)
        try settings.userDefaults.set(
            JSONEncoder().encode(["claude": claude]),
            forKey: MenuBarLayoutUserDefaultsKey.overrides)

        let reloaded = Self.reloadSettingsStore(settings)
        #expect(reloaded.menuBarLayoutOverrides[.cursor] == nil)
        #expect(reloaded.menuBarLayoutOverrides[.claude] == claude)
    }

    @Test
    @MainActor
    func `lane layout load falls back to the legacy blob when the current key is missing`() throws {
        let settings = testSettingsStore(suiteName: "MenuBarLayoutTests-lane-legacy-only")
        let fallback = MenuBarLayout(lines: [[.icon, .percent(window: .weekly)]])
        try settings.userDefaults.set(
            JSONEncoder().encode(fallback),
            forKey: MenuBarLayoutUserDefaultsKey.layout)
        try settings.userDefaults.set(
            JSONEncoder().encode(["cursor": fallback]),
            forKey: MenuBarLayoutUserDefaultsKey.overrides)

        let reloaded = Self.reloadSettingsStore(settings)
        #expect(reloaded.menuBarLayout == fallback)
        #expect(reloaded.menuBarLayoutOverrides[.cursor] == fallback)
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

    private static func writeStartupMigrationProof(
        beforeKeys: [String],
        currentGlobal: Data,
        legacyGlobal: Data,
        currentOverrides: Data,
        legacyOverrides: Data)
    {
        guard let dir = ProcessInfo.processInfo.environment["CODEXBAR_LAYOUT_PROOF_DIR"] else { return }
        let directory = URL(
            fileURLWithPath: NSString(string: dir).expandingTildeInPath,
            isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "fixture": "pre-V2 menuBarLayout keys only, then SettingsStore.init",
            "beforeKeys": beforeKeys,
            "afterKeys": [
                MenuBarLayoutUserDefaultsKey.layout,
                MenuBarLayoutUserDefaultsKey.layoutCurrent,
                MenuBarLayoutUserDefaultsKey.overrides,
                MenuBarLayoutUserDefaultsKey.overridesCurrent,
            ],
            "v2GlobalJSON": String(data: currentGlobal, encoding: .utf8) ?? "",
            "legacyGlobalJSON": String(data: legacyGlobal, encoding: .utf8) ?? "",
            "v2OverridesJSON": String(data: currentOverrides, encoding: .utf8) ?? "",
            "legacyOverridesJSON": String(data: legacyOverrides, encoding: .utf8) ?? "",
            "legacyGlobalDecodesOn0530": true,
            "inMemoryKeepsLaneTokens": true,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: directory.appendingPathComponent("menubar-lane-startup-migration.json"), options: .atomic)
    }
}

/// Mirrors the 0.53.x `MenuBarLayoutToken` surface so downgrade tests can prove `lanePercent`
/// never lands in the legacy UserDefaults blobs.
private enum PreLanePercentMenuBarLayoutToken: Codable, Equatable {
    case icon
    case providerName
    case accountLabel
    case percent(window: PercentWindow)
    case pace(window: PercentWindow)
    case usageBar
    case resetCountdown
    case resetAbsolute
    case runsOut
    case runsOutCompact
    case balance
    case costToday
    case cost30d
    case separatorDot
    case space
}

private struct PreLanePercentMenuBarLayout: Codable, Equatable {
    let lines: [[PreLanePercentMenuBarLayoutToken]]
}
