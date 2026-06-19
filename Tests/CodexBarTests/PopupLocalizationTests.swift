import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct PopupLocalizationTests {
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
    func `inline dashboard labels use selected localization`() throws {
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

            let dashboard = try #require(model.inlineUsageDashboard)

            #expect(dashboard.kpis.map(\.title) == ["餘額", "今天", "週", "月"])
            #expect(dashboard.points.map(\.label) == ["今天", "週", "月"])
            #expect(dashboard.detailLines.contains("速率限制: 100 / 10s"))
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
}
