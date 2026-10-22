import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct UserFacingLocalizationCoverageTests {
    @MainActor
    @Test
    func `shared provider error presentation follows the app language`() {
        let settings = testSettingsStore(
            suiteName: "ProviderErrorLocalization",
            userDefaults: InMemoryUserDefaults(),
            config: CodexBarConfig(providers: []))
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        store.errors[.parallel] = "Login failed"
        CodexBarLocalizationOverride.$appLanguage.withValue("de") {
            #expect(store.userFacingError(for: .parallel) == L("Login failed"))
            #expect(store.userFacingError(for: .parallel) != "Login failed")
        }
    }

    @Test
    func `OpenAI credential scope captions are translated and preserve the account label`() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CodexBar/Resources")
        let accountKey = "Applies to the selected token account “%@”. Each account keeps its own limits."
        let providerKey = "Applies to the OpenAI API key, not to token accounts."
        let languages = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lproj" }
        #expect(languages.count == 23)
        for language in languages {
            let identifier = language.deletingPathExtension().lastPathComponent
            let source = try String(contentsOf: language.appendingPathComponent("Localizable.strings"), encoding: .utf8)
            #expect(source.contains("\"\(accountKey)\" ="))
            #expect(source.contains("\"\(providerKey)\" ="))
            CodexBarLocalizationOverride.$appLanguage.withValue(identifier) {
                let account = L(accountKey, "Synthetic Account")
                let provider = L(providerKey)
                #expect(account.contains("Synthetic Account"))
                #expect(!account.contains("%@"))
                if identifier != "en" {
                    #expect(account != accountKey.replacingOccurrences(of: "%@", with: "Synthetic Account"))
                    #expect(provider != providerKey)
                }
            }
        }
    }

    @Test
    func `selected user-facing UI surfaces avoid raw English literals`() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let forbiddenMarkersByFile: [String: [String]] = [
            "Sources/CodexBar/CostHistoryChartMenuView.swift": [
                ".value(\"Day\"",
                ".value(\"Cost\"",
                ".value(\"Cap start\"",
                ".value(\"Cap end\"",
            ],
            "Sources/CodexBar/CreditsHistoryChartMenuView.swift": [
                ".value(\"Day\"",
                ".value(\"Credits used\"",
                ".value(\"Cap start\"",
                ".value(\"Cap end\"",
                "Text(\"Total (30d):",
                "\\(total) credits",
                "\\(used) credits",
            ],
            "Sources/CodexBar/PlanUtilizationHistoryChartMenuView.swift": [
                ".value(\"Series\"",
                ".value(\"Capacity Start\"",
                ".value(\"Capacity End\"",
                ".value(\"Utilization Start\"",
                ".value(\"Utilization End\"",
            ],
            "Sources/CodexBar/Providers/JetBrains/JetBrainsLoginFlow.swift": [
                "                \"Install a JetBrains IDE with AI Assistant enabled, then refresh CodexBar.\",",
                "                \"Alternatively, set a custom path in Settings.\",",
                "title: \"No JetBrains IDE detected\"",
            ],
            "Sources/CodexBar/PreferencesCodexAccountsSection.swift": [
                "?? \"No system account\"",
                "return \"Adding Account…\"",
                "return \"Add Account\"",
                "return \"Re-authenticating…\"",
                "return \"Re-auth\"",
                "ProviderSettingsSection(title: \"Accounts\")",
                "Text(\"Active\")",
                "Text(\"Choose which Codex account CodexBar should follow.\")",
                "Text(\"Account\")",
                "Text(\"No Codex accounts detected yet.\")",
                "Text(\"System\")",
                "Text(\"The default Codex account on this Mac.\")",
                "Text(\"(System)\")",
                "Button(\"Remove\")",
            ],
            "Sources/CodexBar/PreferencesProviderDetailView.swift": [
                ".help(\"Refresh\")",
                "accessibilityLabel: \"Usage used\"",
            ],
            "Sources/CodexBar/PreferencesProviderErrorView.swift": [
                ".help(\"Copy error\")",
            ],
            "Sources/CodexBar/PreferencesSpendDashboardPane.swift": [
                "Text(\"Partial estimate\")",
            ],
            "Sources/CodexBar/PreferencesMenuPane.swift": [
                "title: \"Stay Awake\",",
            ],
            "Sources/CodexBar/PreferencesTransferSection.swift": [
                "Text(\"Portable Preferences\")",
                "Button(\"Export…\")",
                "Button(\"Import…\")",
                "Text(\"Shortcuts\")",
            ],
            "Sources/CodexBar/ShareStatsCardView.swift": [
                "Text(\"LOCAL SNAPSHOT\")",
                "Label(\"LOCAL · AGGREGATE ONLY\"",
            ],
            "Sources/CodexBarWidget/WidgetTiles.swift": [
                "String(describing: Text(reset, style: .relative))",
            ],
            "Sources/CodexBar/PreferencesNotificationsPane.swift": [
                "\"Credential expiry\"",
                "\"Notify once when a provider account needs you to sign in again.\"",
            ],
            "Sources/CodexBar/UsageStore+CredentialNotifications.swift": [
                " needs sign-in\"",
                "\"Open CodexBar to review the account error and sign in again.\"",
            ],
            "Sources/CodexBar/SpendDashboardProviderBreakdown.swift": [
                "Text(\"Model breakdown unavailable\")",
                "Text(\"Partial model breakdown\")",
                "Text(\"No model-level history\")",
            ],
            "Sources/CodexBar/PreferencesProviderSettingsRows.swift": [
                "Text(self.title)",
                "Text(self.toggle.title)",
                "Text(self.toggle.subtitle)",
                "Button(action.title)",
                "Text(self.picker.title)",
                "Text(option.title)",
                "Text(trimmedTitle)",
                "Text(trimmedSubtitle)",
                "Text(self.descriptor.title)",
                "Text(self.descriptor.subtitle)",
                "Text(\"No token accounts yet.\")",
                "Button(\"Remove\")",
                "TextField(\"Label\"",
                "Button(\"Add\")",
                "TextField(\"Org ID (optional)\"",
                ".help(\"Optional organization ID for accounts linked to multiple Anthropic organizations.\")",
                "Button(\"Open token file\")",
                "Button(\"Reload\")",
                "Text(\"No organizations loaded. Click Refresh after setting your API key.\")",
                "Button(\"Refresh organizations\")",
            ],
            "Sources/CodexBar/PreferencesSidebar.swift": [
                "\"Disabled —",
                ".accessibilityLabel(\"Sort",
            ],
            "Sources/CodexBar/StatusItemController+CostMenuCard.swift": [
                "static let costMenuTitle",
            ],
            "Sources/CodexBar/UsageBreakdownChartMenuView.swift": [
                ".value(\"Day\"",
                ".value(\"Credits used\"",
                ".value(\"Service\"",
                ".value(\"Cap start\"",
                ".value(\"Cap end\"",
            ],
        ]

        var violations: [String] = []
        for (relativePath, markers) in forbiddenMarkersByFile.sorted(by: { $0.key < $1.key }) {
            let source = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            for marker in markers where source.contains(marker) {
                violations.append("\(relativePath): \(marker)")
            }
        }

        #expect(
            violations.isEmpty,
            "Raw user-facing localization markers remain:\n\(violations.joined(separator: "\n"))")
    }

    @Test
    func `credential expiry settings and alerts follow the selected language`() {
        let translations = [
            (
                "en",
                "Credential expiry",
                "Notify once when a provider account needs you to sign in again.",
                "Codex needs sign-in",
                "Open CodexBar to review the account error and sign in again."),
            (
                "zh-Hans",
                "登录凭据过期",
                "当服务商账户需要重新登录时，发送一次通知。",
                "Codex 需要重新登录",
                "打开 CodexBar 查看账户错误并重新登录。"),
            (
                "zh-Hant",
                "登入憑證過期",
                "當服務商帳戶需要重新登入時，傳送一次通知。",
                "Codex 需要重新登入",
                "開啟 CodexBar 查看帳戶錯誤並重新登入。"),
        ]
        for (language, title, subtitle, alertTitle, alertBody) in translations {
            CodexBarLocalizationOverride.$appLanguage.withValue(language) {
                #expect(L("credential_expiry_notifications_title") == title)
                #expect(L("credential_expiry_notifications_subtitle") == subtitle)
                #expect(L("credential_expiry_notification_title", "Codex") == alertTitle)
                #expect(L("credential_expiry_notification_body") == alertBody)
            }
        }
    }

    @Test
    func `provider detail localization preserves technical identifiers`() throws {
        let details = try [
            ProviderDetailSection(
                title: "Usage",
                rows: [
                    .init(label: "Balance", value: "$12.34"),
                    .init(label: "Top model", value: "deepseek-v4-flash"),
                ],
                chart: .init(
                    kind: .bars,
                    title: "Usage",
                    unit: "tokens",
                    points: [.init(label: "2026-08-20", value: 42)])),
        ]

        let localized = CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            UsageMenuCardView.Model.localizedProviderDetails(details, provider: .deepseek)
        }

        let section = try #require(localized.first)
        #expect(section.title == "用量")
        #expect(section.rows.map(\.label) == ["余额", "最常用模型"])
        #expect(section.rows.map(\.value) == ["$12.34", "deepseek-v4-flash"])
        #expect(section.chart?.title == "用量")
        #expect(section.chart?.unit == "token")
        #expect(section.chart?.points.first?.label == "2026-08-20")
    }

    @Test
    func `kiro cap phrases localize of prefixes`() throws {
        let details = try [
            ProviderDetailSection(
                title: "Usage",
                rows: [
                    .init(label: "Overage usage", value: "3603.49 credits", secondaryValue: "of 10000"),
                    .init(label: "Overage cost", value: "$144.14", secondaryValue: "of $400.00"),
                ]),
        ]

        let localized = CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            UsageMenuCardView.Model.localizedProviderDetails(details, provider: .kiro)
        }

        let section = try #require(localized.first)
        #expect(section.rows.map(\.label) == ["超额用量", "超额费用"])
        #expect(section.rows.map(\.value) == ["3603.49 额度", "$144.14"])
        #expect(section.rows.map(\.secondaryValue) == ["/ 10000", "/ $400.00"])
    }

    @Test
    func `grok reset coupon count and expiry localize at presentation`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = GrokRateLimitResetCreditsSnapshot(
            expirations: [now.addingTimeInterval(172_800), now.addingTimeInterval(432_000)],
            updatedAt: now)
        try CodexBarLocalizationOverride.$appLanguage.withValue("ru") {
            let presentation = try #require(LimitResetCreditsPresentation.make(
                snapshot: snapshot, resetStyle: .countdown, now: now))
            #expect(presentation.accessibilityLabel.contains("Кредиты сброса лимита"))
            #expect(presentation.text == "2 доступен")
            #expect(presentation.items.count == 2)
            #expect(presentation.helpText.contains("Истекает"))
        }
    }

    @Test
    func `spend dashboard model breakdown state stays precise and localized`() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/CodexBar/SpendDashboardProviderBreakdown.swift"),
            encoding: .utf8)

        #expect(source.contains(#"L("Model breakdown unavailable")"#))
        #expect(source.contains(#"L("Partial model breakdown")"#))
        #expect(source.contains(#"L("No model-level history")"#))
    }

    @Test
    func `hourly chart accessibility retains localized plurals`() {
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            #expect(spendDashboardHourlyChartAccessibilityValue(hourCount: 1, serviceCount: 1)
                == "1 hour of usage data across 1 service")
            #expect(spendDashboardHourlyChartAccessibilityValue(hourCount: 2, serviceCount: 1)
                == "2 hours of usage data across 1 service")
            #expect(spendDashboardHourlyChartAccessibilityValue(hourCount: 1, serviceCount: 2)
                == "1 hour of usage data across 2 services")
            #expect(spendDashboardHourlyChartAccessibilityValue(hourCount: 2, serviceCount: 2)
                == "2 hours of usage data across 2 services")
        }
    }
}
