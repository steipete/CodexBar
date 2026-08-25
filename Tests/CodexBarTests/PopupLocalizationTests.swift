import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct PopupLocalizationTests {
    @Test
    func `simplified Chinese derives session quota titles from their duration`() throws {
        try CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            for (windowMinutes, expectedTitle) in [(60, "1 小时"), (300, "5 小时"), (720, "12 小时")] {
                let model = try Self.makeClaudeMenuCardModel(primaryWindowMinutes: windowMinutes)

                #expect(model.metrics.first?.title == expectedTitle)
            }
        }
    }

    @Test
    func `simplified Chinese labels a Claude weekly primary fallback accurately`() throws {
        try CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            let model = try Self.makeClaudeMenuCardModel(primaryWindowMinutes: 7 * 24 * 60)

            #expect(model.metrics.first?.title == "每周")
        }
    }

    @Test
    func `simplified Chinese history selector uses quota duration without changing conversations`() {
        CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let histories = [
                PlanUtilizationSeriesHistory(
                    name: .session,
                    windowMinutes: 300,
                    entries: [PlanUtilizationHistoryEntry(capturedAt: now, usedPercent: 10, resetsAt: nil)]),
                PlanUtilizationSeriesHistory(
                    name: .weekly,
                    windowMinutes: 7 * 24 * 60,
                    entries: [PlanUtilizationHistoryEntry(capturedAt: now, usedPercent: 20, resetsAt: nil)]),
            ]
            let snapshot = UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 10,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 20,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: nil,
                    resetDescription: nil),
                updatedAt: now)
            let model = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
                histories: histories,
                provider: .claude,
                snapshot: snapshot)

            #expect(model.visibleSeriesTitles == ["5 小时", "每周"])
            #expect(String(format: L("Session %@"), "abc123") == "会话 abc123")
        }
    }

    @Test
    func `descriptor account labels use selected localization`() throws {
        try CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hant") {
            let suite = "PopupLocalizationTests-descriptor"
            let settings = try Self.makeSettingsStore(suite: suite)
            let store = UsageStore(
                fetcher: UsageFetcher(environment: [:]),
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: settings,
                startupBehavior: .testing)
            store._setSnapshotForTesting(
                UsageSnapshot(
                    primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                    secondary: nil,
                    updatedAt: Date(),
                    identity: ProviderIdentitySnapshot(
                        providerID: .codex,
                        accountEmail: "codex@example.com",
                        accountOrganization: nil,
                        loginMethod: "free")),
                provider: .codex)

            let descriptor = MenuDescriptor.build(
                provider: .codex,
                store: store,
                settings: settings,
                account: AccountInfo(email: nil, plan: nil),
                updateReady: false,
                includeContextualActions: false)

            let lines = Self.textLines(from: descriptor)

            #expect(lines.contains("帳號: codex@example.com"))
            #expect(lines.contains("方案: Free"))
            #expect(!lines.contains("Account: codex@example.com"))
            #expect(!lines.contains("Plan: Free"))
        }
    }

    @Test
    func `factory descriptor localizes every time window label`() throws {
        try CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            let suite = "PopupLocalizationTests-factory-rate-windows"
            let settings = try Self.makeSettingsStore(suite: suite)
            let store = UsageStore(
                fetcher: UsageFetcher(environment: [:]),
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: settings,
                startupBehavior: .testing)
            store._setSnapshotForTesting(
                UsageSnapshot(
                    primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                    secondary: RateWindow(
                        usedPercent: 34,
                        windowMinutes: 10080,
                        resetsAt: nil,
                        resetDescription: nil),
                    tertiary: RateWindow(usedPercent: 56, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                    updatedAt: Date(),
                    identity: nil),
                provider: .factory)

            let descriptor = MenuDescriptor.build(
                provider: .factory,
                store: store,
                settings: settings,
                account: AccountInfo(email: nil, plan: nil),
                updateReady: false,
                includeContextualActions: false)
            let lines = Self.textLines(from: descriptor)

            #expect(lines.contains { $0.hasPrefix("5 小时:") })
            #expect(lines.contains { $0.hasPrefix("每周:") })
            #expect(lines.contains { $0.hasPrefix("每月:") })
            #expect(!lines.contains { $0.hasPrefix("5-hour:") })
        }
    }

    @Test
    func `generic provider details keep canonical labels alongside localized core metrics`() throws {
        try CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hant") {
            let now = Date(timeIntervalSince1970: 1_700_179_200)
            let metadata = try #require(ProviderDefaults.metadata[.openrouter])
            let usage = OpenRouterUsageSnapshot(
                totalCredits: 100,
                totalUsage: 40,
                balance: 60,
                usedPercent: 40,
                keyDataFetched: true,
                keyLimit: 25,
                keyLimitRemaining: 15,
                keyLimitReset: "monthly",
                keyUsage: 10,
                keyUsageDaily: 1.25,
                keyUsageWeekly: 7.5,
                keyUsageMonthly: 18.75,
                rateLimit: OpenRouterRateLimit(requests: 100, interval: "10s"),
                updatedAt: now)

            let model = UsageMenuCardView.Model.make(.init(
                provider: .openrouter,
                metadata: metadata,
                snapshot: usage.toUsageSnapshot(),
                credits: nil,
                creditsError: nil,
                dashboard: nil,
                dashboardError: nil,
                tokenSnapshot: nil,
                tokenError: nil,
                account: AccountInfo(email: nil, plan: nil),
                isRefreshing: false,
                lastError: nil,
                usageBarsShowUsed: false,
                resetTimeDisplayStyle: .countdown,
                tokenCostUsageEnabled: false,
                showOptionalCreditsAndExtraUsage: true,
                hidePersonalInfo: false,
                now: now))

            #expect(model.metrics.first?.title == "額度")
            // After 84a4ca725, generic providers localize section titles and row labels via L();
            // values and chart point labels stay canonical.
            let apiKey = try #require(model.providerDetails.first { $0.title == "API 金鑰" })
            #expect(apiKey.rows.map(\.label) == [
                "API key budget", "API key remaining", "API key used", "Reset window",
                "今天", "本週", "本月", "Rate limit",
            ])
            #expect(apiKey.chart?.points.map(\.label) == ["Today", "This week", "This month"])
            #expect(apiKey.rows.last?.value == "100 requests / 10s")
        }
    }

    @Test
    func `cookie source dynamic subtitles use selected localization`() {
        CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hant") {
            let subtitle = ProviderCookieSourceUI.subtitle(
                source: .manual,
                keychainDisabled: false,
                auto: "Automatically imports browser cookies.",
                manual: "Paste a Cookie header or cURL capture from T3 Chat settings.",
                off: "T3 Chat cookies are disabled.")
            let disabledSubtitle = ProviderCookieSourceUI.subtitle(
                source: .manual,
                keychainDisabled: true,
                auto: "Automatically imports browser cookies.",
                manual: "Paste a Cookie header or cURL capture from T3 Chat settings.",
                off: "T3 Chat cookies are disabled.")
            let jsonBundleSubtitle = ProviderCookieSourceUI.subtitle(
                source: .manual,
                keychainDisabled: false,
                auto: "Automatically imports browser cookies.",
                manual: "Paste the localStorage JSON bundle from Windsurf session.",
                off: "Windsurf cookies are disabled.")

            #expect(subtitle.contains("貼上"))
            #expect(!subtitle.contains("Paste a Cookie"))
            #expect(disabledSubtitle.contains("鑰匙圈"))
            #expect(!disabledSubtitle.contains("Keychain access"))
            #expect(jsonBundleSubtitle.contains("來自 Windsurf session 的 localStorage JSON"))
        }
    }

    @Test
    func `settings labels use selected localization`() {
        CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hant") {
            #expect(KiroMenuBarDisplayMode.hidden.label == "隱藏")
            #expect(KiroMenuBarDisplayMode.creditsLeft.label == "剩餘額度")
            #expect(L("(System)") == "（系統）")
        }
    }

    @Test
    func `provider organization entries preserve provider supplied text`() throws {
        let settings = try Self.makeSettingsStore(suite: "PopupLocalizationTests-organizations")
        settings.kiloKnownOrganizations = [
            KiloOrganization(id: "org_cost", name: "Cost", role: "Today"),
        ]
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let context = ProviderSettingsContext(
            provider: .kilo,
            settings: settings,
            store: store,
            boolBinding: { keyPath in
                Binding(
                    get: { settings[keyPath: keyPath] },
                    set: { settings[keyPath: keyPath] = $0 })
            },
            stringBinding: { keyPath in
                Binding(
                    get: { settings[keyPath: keyPath] },
                    set: { settings[keyPath: keyPath] = $0 })
            },
            statusText: { _ in nil },
            setStatusText: { _, _ in },
            lastAppActiveRunAt: { _ in nil },
            setLastAppActiveRunAt: { _, _ in },
            requestConfirmation: { _ in })
        let descriptor = try #require(KiloProviderImplementation().settingsOrganizations(context: context))
        let orgEntry = try #require(descriptor.entries().first { $0.id == "org_cost" })

        #expect(orgEntry.title == "Cost")
        #expect(orgEntry.localizesTitle == false)
        #expect(orgEntry.subtitle == "Today")
        #expect(orgEntry.localizesSubtitle == false)
    }

    private static func makeSettingsStore(suite: String) throws -> SettingsStore {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        return settings
    }

    private static func textLines(from descriptor: MenuDescriptor) -> [String] {
        descriptor.sections.flatMap(\.entries).compactMap { entry -> String? in
            guard case let .text(text, _) = entry else { return nil }
            return text
        }
    }

    private static func makeClaudeMenuCardModel(primaryWindowMinutes: Int) throws -> UsageMenuCardView.Model {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 10,
                windowMinutes: primaryWindowMinutes,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: nil,
            updatedAt: now)
        return UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))
    }
}
