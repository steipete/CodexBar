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

        _ = GeneralPane(settings: settings, store: store).body
        _ = DisplayPane(settings: settings, store: store).body
        _ = AdvancedPane(settings: settings).body
        _ = ProvidersPane(settings: settings, store: store).body
        _ = DebugPane(settings: settings, store: store).body
        _ = AboutPane(updater: DisabledUpdaterController()).body

        settings.debugDisableKeychainAccess = false
    }

    @Test
    func `builds preference panes with toggled settings`() {
        let settings = Self.makeSettingsStore(suite: "PreferencesPaneSmokeTests-toggled")
        settings.menuBarShowsBrandIconWithPercent = true
        settings.menuBarShowsHighestUsage = true
        settings.showAllTokenAccountsInMenu = true
        settings.hidePersonalInfo = true
        settings.resetTimesShowAbsolute = true
        settings.debugDisableKeychainAccess = true
        settings.claudeOAuthKeychainPromptMode = .always
        settings.refreshFrequency = .manual

        let store = Self.makeUsageStore(settings: settings)
        store._setErrorForTesting("Example error", provider: .codex)

        _ = GeneralPane(settings: settings, store: store).body
        _ = DisplayPane(settings: settings, store: store).body
        _ = AdvancedPane(settings: settings).body
        _ = ProvidersPane(settings: settings, store: store).body
        _ = DebugPane(settings: settings, store: store).body
        _ = AboutPane(updater: DisabledUpdaterController()).body
    }

    @Test
    func `builds preference panes for each supported app language`() {
        let languages = AppLanguage.allCases

        for language in languages {
            let settings = Self.makeSettingsStore(suite: "PreferencesPaneSmokeTests-\(language.rawValue)")
            settings.appLanguage = language
            let store = Self.makeUsageStore(settings: settings)
            let selection = PreferencesSelection()

            _ = PreferencesView(
                settings: settings,
                store: store,
                updater: DisabledUpdaterController(),
                selection: selection).body

            #expect(settings.appLanguage == language)
            let expectedPrefix = language == .system ? Locale.autoupdatingCurrent.identifier : language.rawValue
            #expect(settings.appLocale.identifier.hasPrefix(expectedPrefix))
            #expect(AppLanguage.allCases.map(\.displayName) == ["System", "English", "简体中文", "繁體中文"])

            switch language {
            case .system:
                #expect(!PreferencesView._test_visibleTabTitles(debugMenuEnabled: false).isEmpty)
            case .english:
                AppStrings.withTestingLanguage(.english) {
                    #expect(PreferencesView._test_visibleTabTitles(debugMenuEnabled: false) == [
                        "General",
                        "Providers",
                        "Display",
                        "Advanced",
                        "About",
                    ])
                    #expect(AppStrings.tr("System") == "System")
                    #expect(AppStrings.tr("Language") == "Language")
                    #expect(AppStrings.tr("Quit CodexBar") == "Quit CodexBar")
                }
            case .simplifiedChinese:
                AppStrings.withTestingLanguage(.simplifiedChinese) {
                    #expect(PreferencesView._test_visibleTabTitles(debugMenuEnabled: false) == [
                        "通用",
                        "提供商",
                        "显示",
                        "高级",
                        "关于",
                    ])
                    #expect(AppStrings.tr("System") == "系统")
                    #expect(AppStrings.tr("Language") == "语言")
                    #expect(AppStrings.tr("Quit CodexBar") == "退出 CodexBar")
                }
            case .traditionalChinese:
                AppStrings.withTestingLanguage(.traditionalChinese) {
                    #expect(PreferencesView._test_visibleTabTitles(debugMenuEnabled: false) == [
                        "一般",
                        "供應商",
                        "顯示",
                        "進階",
                        "關於",
                    ])
                    #expect(AppStrings.tr("System") == "系統")
                    #expect(AppStrings.tr("Language") == "語言")
                    #expect(AppStrings.tr("Quit CodexBar") == "結束 CodexBar")
                }
            }
        }
    }

    private static func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

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
