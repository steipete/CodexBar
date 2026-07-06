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
        _ = DisplayPane(settings: settings, store: store).body
        _ = AdvancedPane(settings: settings, store: store).body
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
        settings.menuBarShowsHighestUsage = true
        settings.multiAccountMenuLayout = .stacked
        settings.hidePersonalInfo = true
        settings.resetTimesShowAbsolute = true
        settings.costUsageEnabled = true
        settings.costComparisonPeriodsEnabled = true
        settings.debugDisableKeychainAccess = true
        settings.claudeOAuthKeychainPromptMode = .always
        settings.refreshFrequency = .manual

        let store = Self.makeUsageStore(settings: settings)
        store._setErrorForTesting("Example error", provider: .codex)

        _ = GeneralPane(settings: settings).body
        _ = DisplayPane(settings: settings, store: store).body
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
    func `overview provider limit text formats numeric limit as object argument`() {
        let text = DisplayPane.overviewProviderLimitText(limit: 3)

        #expect(text.contains("3"))
        #expect(!text.contains("%@"))
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
            #expect(L("quota_warning_notifications_title") == "配额预警通知")
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
            #expect(L("tab_display") == "Aspetto")
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
            kimiK2TokenStore: InMemoryKimiK2TokenStore(),
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
