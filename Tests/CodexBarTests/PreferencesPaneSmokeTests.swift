import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct PreferencesPaneSmokeTests {
    @Test
    func `builds preference panes with default settings`() {
        let settings = Self.makeSettingsStore(suite: "PreferencesPaneSmokeTests-default")
        let store = Self.makeUsageStore(settings: settings)

        _ = GeneralPane(settings: settings).body
        _ = NotificationsPane(settings: settings).body
        _ = MenuBarPane(settings: settings, store: store).body
        _ = MenuPane(settings: settings, store: store).body
        _ = AdvancedPane(settings: settings, store: store).body
        _ = HooksPane(settings: settings).body
        _ = ProvidersPane(settings: settings, store: store).body
        _ = DebugPane(settings: settings, store: store).body
        _ = AboutPane(updater: DisabledUpdaterController()).body
        _ = SettingsSidebarView(settings: settings, store: store, selection: .constant(.general)).body

        settings.debugDisableKeychainAccess = false
    }

    @Test
    func `builds preference panes with toggled settings`() {
        let settings = Self.makeSettingsStore(suite: "PreferencesPaneSmokeTests-toggled")
        settings.menuBarShowsBrandIconWithPercent = true
        settings.menuBarHighContrastOnInactiveDisplays = true
        settings.menuBarShowsHighestUsage = true
        settings.multiAccountMenuLayout = .stacked
        settings.hidePersonalInfo = true
        settings.resetTimesShowAbsolute = true
        settings.costUsageEnabled = true
        settings.costComparisonPeriodsEnabled = true
        settings.debugDisableKeychainAccess = true
        settings.claudeOAuthKeychainPromptMode = .always
        settings.refreshFrequency = .manual
        settings.quotaWarningNotificationsEnabled = true

        let store = Self.makeUsageStore(settings: settings)
        store._setErrorForTesting("Example error", provider: .codex)

        _ = GeneralPane(settings: settings).body
        _ = NotificationsPane(settings: settings).body
        _ = MenuBarPane(settings: settings, store: store).body
        _ = MenuPane(settings: settings, store: store).body
        _ = AdvancedPane(settings: settings, store: store).body
        _ = ProvidersPane(provider: .claude, settings: settings, store: store).body
        _ = DebugPane(settings: settings, store: store).body
        _ = AboutPane(updater: DisabledUpdaterController()).body
        _ = SettingsSidebarView(settings: settings, store: store, selection: .constant(.provider(.codex))).body
    }

    @Test
    func `general menu options cover persisted settings`() {
        let previousLanguage = UserDefaults.standard.object(forKey: "appLanguage")
        let previousAppleLanguages = UserDefaults.standard.object(forKey: "AppleLanguages")
        defer {
            if let previousLanguage {
                UserDefaults.standard.set(previousLanguage, forKey: "appLanguage")
            } else {
                UserDefaults.standard.removeObject(forKey: "appLanguage")
            }
            if let previousAppleLanguages {
                UserDefaults.standard.set(previousAppleLanguages, forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            }
        }

        #expect(GeneralSettingsMenuOptions.languages == AppLanguage.allCases.map(\.rawValue))
        #expect(GeneralSettingsMenuOptions.refreshFrequencies == RefreshFrequency.allCases)
        #expect(GeneralSettingsMenuOptions.terminalApps(selected: .terminal) { _ in nil } == [.terminal])
        #expect(GeneralSettingsMenuOptions.terminalApps(selected: .iTerm) { _ in nil } == [.terminal, .iTerm])

        let suite = "PreferencesPaneSmokeTests-general-menu-persistence"
        let settings = Self.makeSettingsStore(suite: suite)
        settings.appLanguage = "ja"
        settings.terminalApp = .iTerm
        settings.refreshFrequency = .fiveMinutes

        let reloaded = Self.makeSettingsStore(suite: suite, reset: false)
        #expect(reloaded.appLanguage == "ja")
        #expect(reloaded.terminalApp == .iTerm)
        #expect(reloaded.refreshFrequency == .fiveMinutes)
    }

    @Test
    func `menu bar and menu options cover persisted settings`() {
        #expect(MenuBarSettingsMenuOptions.displayModes == MenuBarDisplayMode.allCases)
        #expect(MenuBarSettingsMenuOptions.iconStyles == MenuBarIconStyle.allCases)
        #expect(MenuBarSettingsMenuOptions.switcherRows == SwitcherRowsOption.allCases)
        #expect(MenuSettingsMenuOptions.weeklyProgressWorkDays == [nil, 4, 5, 7])
        #expect(MenuSettingsMenuOptions.weeklyProgressWorkDaysLabel(nil) == L("Automatic"))
        #expect(MenuSettingsMenuOptions.multiAccountLayouts == MultiAccountMenuLayout.allCases)
        #expect(MenuSettingsMenuOptions.usageBarsFill == UsageBarsFillOption.allCases)
        #expect(MenuSettingsMenuOptions.resetTimes == ResetTimesOption.allCases)
        #expect(MenuSettingsMenuOptions.costSummaries == CostSummaryOption.allCases)
        #expect(NotificationsSettingsMenuOptions.confettiCelebrations == ConfettiCelebrationOption.allCases)

        let suite = "PreferencesPaneSmokeTests-display-menu-persistence"
        let settings = Self.makeSettingsStore(suite: suite)
        settings.menuBarDisplayMode = .resetTime
        settings.weeklyProgressWorkDays = 7
        settings.multiAccountMenuLayout = .stacked
        settings.costSummaryDisplayStyle = .costSubmenu

        let reloaded = Self.makeSettingsStore(suite: suite, reset: false)
        #expect(reloaded.menuBarDisplayMode == .resetTime)
        #expect(reloaded.weeklyProgressWorkDays == 7)
        #expect(reloaded.multiAccountMenuLayout == .stacked)
        #expect(reloaded.costSummaryDisplayStyle == .costSubmenu)
    }

    @Test
    func `overview provider limit text shows the configured maximum`() {
        let text = MenuBarPane.overviewProviderLimitText()

        #expect(text.contains("6"))
        #expect(!text.contains("%@"))
    }

    @Test
    func `inactive display contrast is available only for icon and percent`() {
        #expect(!MenuBarPane.inactiveDisplayContrastAvailable(for: .critters))
        #expect(!MenuBarPane.inactiveDisplayContrastAvailable(for: .bars))
        #expect(MenuBarPane.inactiveDisplayContrastAvailable(for: .iconAndPercent))
    }

    @Test
    func `menu bar icon style maps existing booleans`() {
        let settings = Self.makeSettingsStore(suite: "PreferencesPaneSmokeTests-menu-bar-icon-style")

        settings.menuBarShowsBrandIconWithPercent = false
        settings.menuBarHidesCritters = false
        #expect(settings.menuBarIconStyle == .critters)

        settings.menuBarHidesCritters = true
        #expect(settings.menuBarIconStyle == .bars)

        settings.menuBarShowsBrandIconWithPercent = true
        #expect(settings.menuBarIconStyle == .iconAndPercent)

        settings.menuBarHidesCritters = true
        settings.menuBarIconStyle = .iconAndPercent
        #expect(settings.menuBarShowsBrandIconWithPercent)
        #expect(settings.menuBarHidesCritters)

        settings.menuBarIconStyle = .critters
        #expect(!settings.menuBarShowsBrandIconWithPercent)
        #expect(!settings.menuBarHidesCritters)

        settings.menuBarIconStyle = .bars
        #expect(!settings.menuBarShowsBrandIconWithPercent)
        #expect(settings.menuBarHidesCritters)
    }

    @Test
    func `confetti celebration option maps all boolean combinations`() {
        let settings = Self.makeSettingsStore(suite: "PreferencesPaneSmokeTests-confetti-celebration")

        for option in ConfettiCelebrationOption.allCases {
            settings.confettiCelebrationOption = option
            #expect(settings.confettiCelebrationOption == option)
            #expect(settings.confettiOnSessionLimitResetsEnabled == (option == .session || option == .both))
            #expect(settings.confettiOnWeeklyLimitResetsEnabled == (option == .weekly || option == .both))
        }
    }

    @Test
    func `cost summary option disables without losing style`() {
        let settings = Self.makeSettingsStore(suite: "PreferencesPaneSmokeTests-cost-summary-option")

        settings.costSummaryOption = .costSubmenu
        #expect(settings.costUsageEnabled)
        #expect(settings.costSummaryDisplayStyle == .costSubmenu)

        settings.costSummaryOption = .off
        #expect(!settings.costUsageEnabled)
        #expect(settings.costSummaryDisplayStyle == .costSubmenu)
        #expect(settings.costSummaryOption == .off)

        settings.costUsageEnabled = true
        #expect(settings.costSummaryOption == .costSubmenu)

        settings.costSummaryOption = .inlineSummary
        #expect(settings.costUsageEnabled)
        #expect(settings.costSummaryDisplayStyle == .inlineSummary)

        settings.costSummaryOption = .both
        #expect(settings.costUsageEnabled)
        #expect(settings.costSummaryDisplayStyle == .both)
    }

    @Test
    func `cost history days editor builds with clamped settings binding`() {
        let settings = Self.makeSettingsStore(suite: "PreferencesPaneSmokeTests-cost-history-days")

        settings.costUsageHistoryDays = 999
        #expect(settings.costUsageHistoryDays == 365)
        #expect(CostHistoryDaysEditor.title(days: 365).contains("365"))
        #expect(!CostHistoryDaysEditor.title(days: 365).contains("%d"))

        _ = CostHistoryDaysEditor(settings: settings).body
    }

    @Test
    func `quota warning compact threshold text filters and persists typed values`() {
        let suite = "PreferencesPaneSmokeTests-quota-warning-threshold-editor"
        let settings = Self.makeSettingsStore(suite: suite)

        #expect(QuotaWarningThresholdEditorText.filteredIntegerText("9a8b7") == "98")
        #expect(QuotaWarningThresholdEditorText.resolvedThresholds(upperText: "", lowerText: "12") == [50, 12])

        let typedThresholds = QuotaWarningThresholdEditorText.resolvedThresholds(upperText: "75", lowerText: "15")
        settings.setQuotaWarningThresholds(.session, thresholds: typedThresholds)

        #expect(settings.quotaWarningThresholds(.session) == [75, 15])
        let reloaded = Self.makeSettingsStore(suite: suite, reset: false)
        #expect(reloaded.quotaWarningThresholds(.session) == [75, 15])
    }

    @Test
    func `quota warning compact draft preserves untouched threshold lists`() {
        var singleThreshold = QuotaWarningThresholdEditorText.Draft(thresholds: [50])
        var severalThresholds = QuotaWarningThresholdEditorText.Draft(thresholds: [80, 50, 20])

        #expect(singleThreshold.takeResolvedThresholds() == nil)
        #expect(severalThresholds.takeResolvedThresholds() == nil)
        #expect(singleThreshold.isDirty == false)
        #expect(severalThresholds.isDirty == false)
    }

    @Test
    func `quota warning compact draft commits only changed text`() {
        var draft = QuotaWarningThresholdEditorText.Draft(thresholds: [80, 50, 20])

        draft.setText("80", for: .upper)
        #expect(draft.isDirty == false)

        draft.setText("7a5", for: .upper)
        #expect(draft.isDirty == true)
        #expect(draft.takeResolvedThresholds() == [75, 50])
        #expect(draft.isDirty == false)
        #expect(draft.text(for: .upper) == "75")
        #expect(draft.text(for: .lower) == "50")
    }

    @Test
    func `quota warning compact draft treats reverted text as unchanged`() {
        var draft = QuotaWarningThresholdEditorText.Draft(thresholds: [80, 50, 20])

        draft.setText("79", for: .upper)
        #expect(draft.isDirty == true)

        draft.setText("80", for: .upper)
        #expect(draft.isDirty == false)
        #expect(draft.takeResolvedThresholds() == nil)
    }

    @Test
    func `quota warning compact window toggle keeps thresholds while disabled`() {
        let settings = Self.makeSettingsStore(suite: "PreferencesPaneSmokeTests-quota-warning-disabled-window")

        settings.setQuotaWarningThresholds(.weekly, thresholds: [80, 30])
        settings.setQuotaWarningWindowEnabled(.weekly, enabled: false)

        #expect(settings.quotaWarningWindowEnabled(.weekly) == false)
        #expect(settings.quotaWarningThresholds(.weekly) == [80, 30])

        settings.setQuotaWarningWindowEnabled(.weekly, enabled: true)

        #expect(settings.quotaWarningWindowEnabled(.weekly) == true)
        #expect(settings.quotaWarningThresholds(.weekly) == [80, 30])
    }

    @Test
    func `quota warning compact rows build with semantic threshold labels`() {
        let settings = Self.makeSettingsStore(suite: "PreferencesPaneSmokeTests-quota-warning-semantic-labels")
        settings.quotaWarningNotificationsEnabled = true

        CodexBarLocalizationOverride.$appLanguage.withValue("ru") {
            #expect(L("quota_warning_global") == "Глобально")
            #expect(L("quota_warning_warning") == "Предупреждение")
            #expect(L("quota_warning_critical") == "Критично")

            _ = GlobalQuotaWarningSettingsView(settings: settings).body
        }
    }

    @Test
    func `provider quota warning inherited summary keeps additional active thresholds visible`() {
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            let thresholdText = ProviderQuotaWarningSettingsView.thresholdText([80, 50, 20], enabled: true)

            #expect(thresholdText == "Warning 80%, Critical 50%, 20%")
            #expect(String(format: L("quota_warning_inherited"), thresholdText)
                == "Inherited: Warning 80%, Critical 50%, 20%")
        }
    }

    @Test
    func `provider quota warning rows build for global custom and off states`() {
        let settings = Self.makeSettingsStore(suite: "PreferencesPaneSmokeTests-provider-quota-warning-rows")
        settings.quotaWarningNotificationsEnabled = true
        settings.setQuotaWarningThresholds(.session, thresholds: [50, 20])
        settings.setQuotaWarningThresholds(.weekly, thresholds: [80, 40])

        _ = ProviderQuotaWarningSettingsView(provider: .codex, settings: settings).body

        settings.setQuotaWarningOverride(provider: .codex, window: .session, thresholds: [70, 30], enabled: true)
        settings.setQuotaWarningOverride(provider: .codex, window: .weekly, thresholds: [60, 10], enabled: false)

        _ = ProviderQuotaWarningSettingsView(provider: .codex, settings: settings).body

        #expect(settings.hasQuotaWarningOverride(provider: .codex, window: .session))
        #expect(settings.hasQuotaWarningOverride(provider: .codex, window: .weekly))
        #expect(settings.quotaWarningEnabled(provider: .codex, window: .session))
        #expect(!settings.quotaWarningEnabled(provider: .codex, window: .weekly))
        #expect(settings.resolvedQuotaWarningThresholds(provider: .codex, window: .weekly) == [60, 10])
    }

    @Test
    func `provider quota warning controls follow notification and marker visibility`() {
        let settings = Self.makeSettingsStore(suite: "PreferencesPaneSmokeTests-provider-quota-warning-disabled")
        settings.quotaWarningNotificationsEnabled = true
        settings.quotaWarningMarkersVisible = true
        settings.setQuotaWarningOverride(provider: .codex, window: .session, thresholds: [70, 30], enabled: true)
        settings.setQuotaWarningOverride(provider: .codex, window: .weekly, thresholds: [60, 10], enabled: false)

        let view = ProviderQuotaWarningSettingsView(provider: .codex, settings: settings)
        let inheritedView = ProviderQuotaWarningSettingsView(provider: .claude, settings: settings)
        #expect(view.controlsEnabled)
        #expect(view.overrideMode(for: .session) == .custom)
        #expect(view.overrideMode(for: .weekly) == .off)
        #expect(inheritedView.overrideMode(for: .session) == .global)
        #expect(inheritedView.overrideMode(for: .weekly) == .global)

        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            #expect(view.footerText == "Uses the global quota warning settings unless a window is customized here.")
        }

        settings.quotaWarningNotificationsEnabled = false

        #expect(view.controlsEnabled)
        #expect(inheritedView.controlsEnabled)
        #expect(view.overrideMode(for: .session) == .custom)
        #expect(view.overrideMode(for: .weekly) == .off)
        #expect(inheritedView.overrideMode(for: .session) == .global)
        #expect(inheritedView.overrideMode(for: .weekly) == .global)
        #expect(settings.explicitQuotaWarningThresholds(provider: .codex, window: .session) == [70, 30])
        #expect(settings.explicitQuotaWarningThresholds(provider: .codex, window: .weekly) == [60, 10])

        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            #expect(view.footerText == "Quota warning notifications are disabled globally. " +
                "These settings still control usage-bar markers.")
        }

        settings.quotaWarningMarkersVisible = false
        settings.predictivePaceWarningNotificationsEnabled = true

        #expect(!view.controlsEnabled)
        #expect(!inheritedView.controlsEnabled)

        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            #expect(view.footerText == "Quota warning notifications and usage-bar markers are disabled. " +
                "Enable either to edit these saved settings.")
        }

        settings.quotaWarningNotificationsEnabled = true

        #expect(view.controlsEnabled)
        #expect(inheritedView.controlsEnabled)
        #expect(view.overrideMode(for: .session) == .custom)
        #expect(view.overrideMode(for: .weekly) == .off)
        #expect(inheritedView.overrideMode(for: .session) == .global)
        #expect(inheritedView.overrideMode(for: .weekly) == .global)

        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            #expect(view.footerText == "Uses the global quota warning settings unless a window is customized here.")
        }
    }

    @Test
    func `provider quota warning mode binding applies global custom and off transitions`() {
        let settings = Self.makeSettingsStore(suite: "PreferencesPaneSmokeTests-provider-quota-warning-mode-binding")
        settings.quotaWarningNotificationsEnabled = true
        settings.setQuotaWarningWindowEnabled(.session, enabled: true)
        settings.setQuotaWarningThresholds(.session, thresholds: [50, 20])

        let view = ProviderQuotaWarningSettingsView(provider: .codex, settings: settings)
        let mode = view.overrideModeBinding(for: .session)

        #expect(mode.wrappedValue == .global)

        mode.wrappedValue = .custom
        #expect(mode.wrappedValue == .custom)
        #expect(settings.hasQuotaWarningOverride(provider: .codex, window: .session))
        #expect(settings.quotaWarningEnabled(provider: .codex, window: .session))
        #expect(settings.providerConfig(for: .codex)?.quotaWarnings?.session?.thresholds == nil)
        #expect(settings.resolvedQuotaWarningThresholds(provider: .codex, window: .session) == [50, 20])
        #expect(view.shouldCommitThresholdEditorOnDisappear(for: .session))

        settings.setQuotaWarningThresholds(provider: .codex, window: .session, thresholds: [70, 30])
        mode.wrappedValue = .off
        #expect(mode.wrappedValue == .off)
        #expect(settings.hasQuotaWarningOverride(provider: .codex, window: .session))
        #expect(!settings.quotaWarningEnabled(provider: .codex, window: .session))
        #expect(settings.resolvedQuotaWarningThresholds(provider: .codex, window: .session) == [70, 30])
        #expect(view.shouldCommitThresholdEditorOnDisappear(for: .session))

        mode.wrappedValue = .custom
        #expect(mode.wrappedValue == .custom)
        #expect(settings.quotaWarningEnabled(provider: .codex, window: .session))
        #expect(settings.explicitQuotaWarningThresholds(provider: .codex, window: .session) == [70, 30])
        #expect(settings.resolvedQuotaWarningThresholds(provider: .codex, window: .session) == [70, 30])

        mode.wrappedValue = .global
        #expect(mode.wrappedValue == .global)
        #expect(!settings.hasQuotaWarningOverride(provider: .codex, window: .session))
        #expect(settings.quotaWarningEnabled(provider: .codex, window: .session))
        #expect(settings.resolvedQuotaWarningThresholds(provider: .codex, window: .session) == [50, 20])
        #expect(!view.shouldCommitThresholdEditorOnDisappear(for: .session))

        mode.wrappedValue = .custom
        #expect(settings.providerConfig(for: .codex)?.quotaWarnings?.session?.thresholds == nil)

        mode.wrappedValue = .off
        let disabledInheritedConfig = settings.providerConfig(for: .codex)?.quotaWarnings?.session
        #expect(disabledInheritedConfig?.enabled == false)
        #expect(disabledInheritedConfig?.thresholds == nil)
        #expect(settings.resolvedQuotaWarningThresholds(provider: .codex, window: .session) == [50, 20])
        #expect(view.shouldCommitThresholdEditorOnDisappear(for: .session))
    }

    @Test
    func `language preference updates global localization resolver`() {
        let previousLanguage = UserDefaults.standard.object(forKey: "appLanguage")
        let previousAppleLanguages = UserDefaults.standard.object(forKey: "AppleLanguages")
        defer {
            if let previousLanguage {
                UserDefaults.standard.set(previousLanguage, forKey: "appLanguage")
            } else {
                UserDefaults.standard.removeObject(forKey: "appLanguage")
            }
            if let previousAppleLanguages {
                UserDefaults.standard.set(previousAppleLanguages, forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            }
        }

        let settings = Self.makeSettingsStore(suite: "PreferencesPaneSmokeTests-language")

        settings.appLanguage = "zh-Hans"

        #expect(UserDefaults.standard.string(forKey: "appLanguage") == "zh-Hans")
        CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            #expect(L("tab_general") == "通用")
            #expect(L("threshold_warnings_title") == "阈值预警")
            #expect(L("show_provider_storage_usage_title") == "显示提供商存储用量")
        }

        settings.appLanguage = "ja"

        #expect(UserDefaults.standard.string(forKey: "appLanguage") == "ja")
        CodexBarLocalizationOverride.$appLanguage.withValue("ja") {
            #expect(L("language_title") == "言語")
            #expect(L("start_at_login_title") == "ログイン時に起動")
            #expect(L("quit_app") == "CodexBar を終了")
        }

        settings.appLanguage = "id"

        #expect(UserDefaults.standard.string(forKey: "appLanguage") == "id")
        CodexBarLocalizationOverride.$appLanguage.withValue("id") {
            #expect(L("language_title") == "Bahasa")
            #expect(L("start_at_login_title") == "Mulai saat Login")
            #expect(L("quit_app") == "Keluar CodexBar")
        }
    }

    @Test
    func `language preference clears stale app level AppleLanguages override`() {
        let previousLanguage = UserDefaults.standard.object(forKey: "appLanguage")
        let previousAppleLanguages = UserDefaults.standard.object(forKey: "AppleLanguages")
        defer {
            if let previousLanguage {
                UserDefaults.standard.set(previousLanguage, forKey: "appLanguage")
            } else {
                UserDefaults.standard.removeObject(forKey: "appLanguage")
            }
            if let previousAppleLanguages {
                UserDefaults.standard.set(previousAppleLanguages, forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            }
        }

        let staleOverride = ["zz-StaleLanguageOverride"]
        UserDefaults.standard.set(staleOverride, forKey: "AppleLanguages")

        let settings = Self.makeSettingsStore(suite: "PreferencesPaneSmokeTests-language-system")
        settings.appLanguage = "ko"

        #expect(UserDefaults.standard.string(forKey: "appLanguage") == "ko")
        #expect(UserDefaults.standard.object(forKey: "AppleLanguages") as? [String] != staleOverride)

        settings.appLanguage = ""

        #expect(UserDefaults.standard.object(forKey: "appLanguage") == nil)
        #expect(UserDefaults.standard.object(forKey: "AppleLanguages") as? [String] != staleOverride)
    }

    @Test
    func `german app language resolves localized labels`() {
        let settings = Self.makeSettingsStore(suite: "PreferencesPaneSmokeTests-language-de")
        settings.appLanguage = "de"

        #expect(UserDefaults.standard.string(forKey: "appLanguage") == "de")
        CodexBarLocalizationOverride.$appLanguage.withValue("de") {
            #expect(L("tab_general") == "Allgemein")
            #expect(L("language_title") == "Sprache")
            #expect(L("quit_app") == "CodexBar beenden")
            #expect(L("display_mode_reset_time") == "Zurücksetzungszeit")
            #expect(L("display_mode_reset_time_desc").contains("↻ 15:56"))
            #expect(L("vertex_ai_login_instructions").contains("\n\n1. Öffnen Sie Terminal"))
            #expect(!L("vertex_ai_login_instructions").contains("\\n"))
        }
    }

    @Test
    func `italian language preference resolves italian strings`() {
        let settings = Self.makeSettingsStore(suite: "PreferencesPaneSmokeTests-language-italian")
        settings.appLanguage = "it"

        #expect(UserDefaults.standard.string(forKey: "appLanguage") == "it")
        CodexBarLocalizationOverride.$appLanguage.withValue("it") {
            #expect(L("language_title") == "Lingua")
            #expect(L("section_system") == "Sistema")
            #expect(L("language_italian") == "Italiano")
            #expect(L("tab_menu_bar") == "Barra menu")
            #expect(L("tab_advanced") == "Avanzate")
            #expect(L("quit_app") == "Esci da CodexBar")
        }
    }

    private static func makeSettingsStore(suite: String, reset: Bool = true) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        if reset {
            defaults.removePersistentDomain(forName: suite)
        }
        let configStore = testConfigStore(suiteName: suite, reset: reset)

        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
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

    private static func makeUsageStore(settings: SettingsStore) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
    }
}
