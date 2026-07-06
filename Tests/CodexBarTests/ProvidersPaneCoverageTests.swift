import AppKit
import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct ProvidersPaneCoverageTests {
    @Test
    func `exercises providers pane views`() {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests")
        let store = Self.makeUsageStore(settings: settings)

        ProvidersPaneTestHarness.exercise(settings: settings, store: store)
    }

    @Test
    func `claude token account descriptor shows organization field`() throws {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-claude-org-field")
        let store = Self.makeUsageStore(settings: settings)
        let pane = ProvidersPane(settings: settings, store: store)

        let claudeDescriptor = try #require(pane._test_tokenAccountDescriptor(for: .claude))
        #expect(claudeDescriptor.showsOrganizationField)

        let copilotDescriptor = try #require(pane._test_tokenAccountDescriptor(for: .copilot))
        #expect(!copilotDescriptor.showsOrganizationField)
    }

    @Test
    func `zai token account descriptor shows team mode controls only for zai`() throws {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-zai-team-controls")
        let store = Self.makeUsageStore(settings: settings)
        let pane = ProvidersPane(settings: settings, store: store)

        let zaiDescriptor = try #require(pane._test_tokenAccountDescriptor(for: .zai))
        #expect(zaiDescriptor.showsTeamModeControls)
        #expect(!zaiDescriptor.showsOrganizationField)

        let claudeDescriptor = try #require(pane._test_tokenAccountDescriptor(for: .claude))
        #expect(!claudeDescriptor.showsTeamModeControls)
        #expect(claudeDescriptor.showsOrganizationField)
    }

    @Test
    func `zai team account add button requires organization and project`() {
        #expect(ProviderSettingsTokenAccountsRowView.isAddDisabled(
            label: "Team",
            token: "token",
            showsTeamModeControls: true,
            teamMode: true,
            teamContext: (organizationID: "", projectID: "proj-test")))
        #expect(ProviderSettingsTokenAccountsRowView.isAddDisabled(
            label: "Team",
            token: "token",
            showsTeamModeControls: true,
            teamMode: true,
            teamContext: (organizationID: "org-test", projectID: "")))
        #expect(!ProviderSettingsTokenAccountsRowView.isAddDisabled(
            label: "Team",
            token: "token",
            showsTeamModeControls: true,
            teamMode: true,
            teamContext: (organizationID: "org-test", projectID: "proj-test")))
        #expect(!ProviderSettingsTokenAccountsRowView.isAddDisabled(
            label: "Personal",
            token: "token",
            showsTeamModeControls: true,
            teamMode: false,
            teamContext: (organizationID: "", projectID: "")))
    }

    @Test
    func `zai team account draft requires complete ids before apply`() {
        let original = ProviderSettingsTokenAccountsRowView.TeamAccountDraft(
            teamMode: false,
            organizationID: "",
            projectID: "")

        #expect(ProviderSettingsTokenAccountsRowView.isTeamDraftApplyDisabled(
            draft: original,
            original: original))
        #expect(ProviderSettingsTokenAccountsRowView.isTeamDraftApplyDisabled(
            draft: ProviderSettingsTokenAccountsRowView.TeamAccountDraft(
                teamMode: true,
                organizationID: "org-test",
                projectID: ""),
            original: original))
        #expect(!ProviderSettingsTokenAccountsRowView.isTeamDraftApplyDisabled(
            draft: ProviderSettingsTokenAccountsRowView.TeamAccountDraft(
                teamMode: true,
                organizationID: "org-test",
                projectID: "proj-test"),
            original: original))
        #expect(!ProviderSettingsTokenAccountsRowView.isTeamDraftApplyDisabled(
            draft: ProviderSettingsTokenAccountsRowView.TeamAccountDraft(
                teamMode: false,
                organizationID: "",
                projectID: ""),
            original: ProviderSettingsTokenAccountsRowView.TeamAccountDraft(
                teamMode: true,
                organizationID: "org-test",
                projectID: "proj-test")))
    }

    @Test
    func `provider search filters display names and raw ids`() {
        let providers: [UsageProvider] = [.codex, .claude, .openrouter, .deepseek]
        let names: [UsageProvider: String] = [
            .codex: "Codex",
            .claude: "Claude",
            .openrouter: "OpenRouter",
            .deepseek: "DeepSeek",
        ]

        #expect(
            ProvidersPane.filteredProviders(providers, query: "  ", displayName: { names[$0] ?? $0.rawValue })
                == providers)
        #expect(
            ProvidersPane.filteredProviders(providers, query: "router", displayName: { names[$0] ?? $0.rawValue })
                == [.openrouter])
        #expect(
            ProvidersPane.filteredProviders(providers, query: "CLA", displayName: { names[$0] ?? $0.rawValue })
                == [.claude])
        #expect(
            ProvidersPane.filteredProviders(providers, query: "deepseek", displayName: { _ in "API" })
                == [.deepseek])
    }

    @Test
    func `provider reordering is inert while alphabetical sorting is enabled`() {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-sorted-reorder")
        let store = Self.makeUsageStore(settings: settings)
        let pane = ProvidersPane(settings: settings, store: store)
        let original = settings.orderedProviders()

        settings.providersSortedAlphabetically = true
        pane._test_moveProviders(fromOffsets: IndexSet(integer: 0), toOffset: original.count)
        #expect(settings.orderedProviders() == original)

        settings.providersSortedAlphabetically = false
        pane._test_moveProviders(fromOffsets: IndexSet(integer: 0), toOffset: original.count)
        #expect(settings.orderedProviders().last == original.first)
    }

    @Test
    @MainActor
    func `settings pane titles cover app panes and providers`() {
        #expect(SettingsPane.general.title == L("tab_general"))
        #expect(SettingsPane.about.title == L("tab_about"))
        #expect(!SettingsPane.provider(.codex).title.isEmpty)
        #expect(SettingsPane.provider(.codex) != SettingsPane.provider(.claude))
    }

    @Test
    func `copilot menu card preview follows budget extras setting`() {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-copilot-budget-preview")
        let store = Self.makeUsageStore(settings: settings)
        let budgetTitle = "Budget - Copilot Agent Premium Requests"
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(usedPercent: 30, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                extraRateWindows: [
                    NamedRateWindow(
                        id: "copilot-budget-agent",
                        title: budgetTitle,
                        window: RateWindow(
                            usedPercent: 65,
                            windowMinutes: nil,
                            resetsAt: nil,
                            resetDescription: nil)),
                ],
                updatedAt: Date()),
            provider: .copilot)
        let pane = ProvidersPane(settings: settings, store: store)

        #expect(!pane._test_menuCardModel(for: .copilot).metrics.map(\.title).contains(budgetTitle))

        settings.copilotBudgetExtrasEnabled = true
        #expect(pane._test_menuCardModel(for: .copilot).metrics.map(\.title).contains(budgetTitle))
    }

    @Test
    func `open router menu bar metric picker shows only automatic and primary`() {
        Self.withEnglishLocalization {
            let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-openrouter-picker")
            let store = Self.makeUsageStore(settings: settings)
            let pane = ProvidersPane(settings: settings, store: store)

            let picker = pane._test_menuBarMetricPicker(for: .openrouter)
            #expect(picker?.options.map(\.id) == [
                MenuBarMetricPreference.automatic.rawValue,
                MenuBarMetricPreference.primary.rawValue,
            ])
            #expect(picker?.options.map(\.title) == [
                "Automatic",
                "Primary (API key limit)",
            ])
        }
    }

    @Test
    func `deepseek menu bar metric picker shows balance only copy`() {
        Self.withEnglishLocalization {
            let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-deepseek-picker")
            let store = Self.makeUsageStore(settings: settings)
            let pane = ProvidersPane(settings: settings, store: store)

            let picker = pane._test_menuBarMetricPicker(for: .deepseek)
            #expect(picker?.options.map(\.id) == [
                MenuBarMetricPreference.automatic.rawValue,
            ])
            #expect(picker?.subtitle == "Shows the DeepSeek balance in the menu bar.")
        }
    }

    @Test
    func `moonshot menu bar metric picker shows balance only copy`() {
        Self.withEnglishLocalization {
            let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-moonshot-picker")
            let store = Self.makeUsageStore(settings: settings)
            let pane = ProvidersPane(settings: settings, store: store)

            let picker = pane._test_menuBarMetricPicker(for: .moonshot)
            #expect(picker?.options.map(\.id) == [
                MenuBarMetricPreference.automatic.rawValue,
            ])
            #expect(picker?.subtitle == "Shows the Moonshot / Kimi API balance in the menu bar.")
        }
    }

    @Test
    func `mistral menu bar metric picker shows payg and monthly plan options`() {
        Self.withEnglishLocalization {
            let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-mistral-picker")
            let store = Self.makeUsageStore(settings: settings)
            let pane = ProvidersPane(settings: settings, store: store)

            let picker = pane._test_menuBarMetricPicker(for: .mistral)
            #expect(picker?.options.map(\.id) == [
                MenuBarMetricPreference.automatic.rawValue,
                MenuBarMetricPreference.monthlyPlan.rawValue,
            ])
            #expect(picker?.options.first?.title == "Pay-as-you-go")
            #expect(picker?.options.last?.title == "Monthly Plan")
            #expect(picker?.subtitle == "Choose Mistral API spend or Monthly Plan usage for the menu bar.")
        }
    }

    @Test
    func `kimi k2 menu bar metric picker shows credits only copy`() {
        Self.withEnglishLocalization {
            let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-kimik2-picker")
            let store = Self.makeUsageStore(settings: settings)
            let pane = ProvidersPane(settings: settings, store: store)

            let picker = pane._test_menuBarMetricPicker(for: .kimik2)
            #expect(picker?.options.map(\.id) == [
                MenuBarMetricPreference.automatic.rawValue,
            ])
            #expect(picker?.subtitle == "Shows Kimi K2 API-key credits in the menu bar.")
        }
    }

    @Test
    func `kimi menu bar metric picker preserves stored lane labels`() {
        Self.withEnglishLocalization {
            let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-kimi-picker")
            let store = Self.makeUsageStore(settings: settings)
            let pane = ProvidersPane(settings: settings, store: store)

            let picker = pane._test_menuBarMetricPicker(for: .kimi)
            #expect(picker?.options.map(\.id) == [
                MenuBarMetricPreference.automatic.rawValue,
                MenuBarMetricPreference.primary.rawValue,
                MenuBarMetricPreference.secondary.rawValue,
            ])
            #expect(picker?.options.map(\.title) == [
                "Automatic",
                "Primary (Weekly)",
                "Secondary (Rate Limit)",
            ])
        }
    }

    @Test
    func `cursor menu bar metric picker omits tertiary api lane when snapshot has no api metric`() {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-cursor-no-tertiary-picker")
        let store = Self.makeUsageStore(settings: settings)
        let pane = ProvidersPane(settings: settings, store: store)

        let picker = pane._test_menuBarMetricPicker(for: .cursor)
        let ids = picker?.options.map(\.id) ?? []
        #expect(!ids.contains(MenuBarMetricPreference.tertiary.rawValue))
    }

    @Test
    func `cursor menu bar metric picker includes tertiary api lane when snapshot has api metric`() {
        Self.withEnglishLocalization {
            let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-cursor-tertiary-picker")
            let store = Self.makeUsageStore(settings: settings)
            store._setSnapshotForTesting(
                UsageSnapshot(
                    primary: RateWindow(usedPercent: 12, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                    secondary: RateWindow(usedPercent: 34, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                    tertiary: RateWindow(usedPercent: 56, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                    updatedAt: Date()),
                provider: .cursor)
            let pane = ProvidersPane(settings: settings, store: store)

            let picker = pane._test_menuBarMetricPicker(for: .cursor)
            let ids = picker?.options.map(\.id) ?? []
            #expect(ids.contains(MenuBarMetricPreference.tertiary.rawValue))
            let tertiaryOption = picker?.options.first { $0.id == MenuBarMetricPreference.tertiary.rawValue }
            #expect(tertiaryOption?.title == "Tertiary (API)")
        }
    }

    @Test
    func `cursor menu bar metric picker omits extra usage when on demand budget is missing`() {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-cursor-no-extra-usage-picker")
        let store = Self.makeUsageStore(settings: settings)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 12, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(usedPercent: 34, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                updatedAt: Date()),
            provider: .cursor)
        let pane = ProvidersPane(settings: settings, store: store)

        let picker = pane._test_menuBarMetricPicker(for: .cursor)
        let ids = picker?.options.map(\.id) ?? []
        #expect(!ids.contains(MenuBarMetricPreference.extraUsage.rawValue))
    }

    @Test
    func `cursor menu bar metric picker includes extra usage when on demand budget is available`() {
        Self.withEnglishLocalization {
            let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-cursor-extra-usage-picker")
            let store = Self.makeUsageStore(settings: settings)
            store._setSnapshotForTesting(
                UsageSnapshot(
                    primary: RateWindow(usedPercent: 12, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                    secondary: RateWindow(usedPercent: 34, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                    tertiary: RateWindow(usedPercent: 56, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                    providerCost: ProviderCostSnapshot(
                        used: 15,
                        limit: 100,
                        currencyCode: "USD",
                        updatedAt: Date()),
                    updatedAt: Date()),
                provider: .cursor)
            let pane = ProvidersPane(settings: settings, store: store)

            let picker = pane._test_menuBarMetricPicker(for: .cursor)
            let ids = picker?.options.map(\.id) ?? []
            #expect(ids.contains(MenuBarMetricPreference.extraUsage.rawValue))
            let option = picker?.options.first { $0.id == MenuBarMetricPreference.extraUsage.rawValue }
            #expect(option?.title == "Extra usage")
        }
    }

    @Test
    func `claude menu bar metric picker includes extra usage when spend limit is available`() {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-claude-extra-usage-picker")
        let store = Self.makeUsageStore(settings: settings)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: nil,
                secondary: nil,
                providerCost: ProviderCostSnapshot(
                    used: 67.03,
                    limit: 1000,
                    currencyCode: "USD",
                    period: "Spend limit",
                    updatedAt: Date()),
                updatedAt: Date()),
            provider: .claude)
        let pane = ProvidersPane(settings: settings, store: store)

        let picker = pane._test_menuBarMetricPicker(for: .claude)
        let ids = picker?.options.map(\.id) ?? []
        #expect(ids.contains(MenuBarMetricPreference.extraUsage.rawValue))
    }

    @Test
    func `claude menu bar metric picker includes session plus weekly lane`() {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-claude-session-weekly-picker")
        let store = Self.makeUsageStore(settings: settings)
        let pane = ProvidersPane(settings: settings, store: store)

        let picker = pane._test_menuBarMetricPicker(for: .claude)
        let ids = picker?.options.map(\.id) ?? []
        #expect(ids.contains(MenuBarMetricPreference.primaryAndSecondary.rawValue))
    }

    @Test
    func `zai menu bar metric picker omits tertiary lane when snapshot has no 5-hour metric`() {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-zai-no-tertiary-picker")
        let store = Self.makeUsageStore(settings: settings)
        let pane = ProvidersPane(settings: settings, store: store)

        let picker = pane._test_menuBarMetricPicker(for: .zai)
        let ids = picker?.options.map(\.id) ?? []
        #expect(ids == [
            MenuBarMetricPreference.automatic.rawValue,
            MenuBarMetricPreference.primary.rawValue,
            MenuBarMetricPreference.secondary.rawValue,
        ])
    }

    @Test
    func `zai menu bar metric picker includes tertiary 5-hour lane when snapshot has it`() {
        Self.withEnglishLocalization {
            let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-zai-tertiary-picker")
            let store = Self.makeUsageStore(settings: settings)
            store._setSnapshotForTesting(
                UsageSnapshot(
                    primary: RateWindow(usedPercent: 12, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
                    secondary: RateWindow(usedPercent: 34, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                    tertiary: RateWindow(usedPercent: 56, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                    updatedAt: Date()),
                provider: .zai)
            let pane = ProvidersPane(settings: settings, store: store)

            let picker = pane._test_menuBarMetricPicker(for: .zai)
            let ids = picker?.options.map(\.id) ?? []
            #expect(ids.contains(MenuBarMetricPreference.tertiary.rawValue))
            let tertiaryOption = picker?.options.first { $0.id == MenuBarMetricPreference.tertiary.rawValue }
            #expect(tertiaryOption?.title == "Tertiary (5-hour)")
        }
    }

    @Test
    func `gemini menu bar metric picker omits tertiary lane`() {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-gemini-no-tertiary-picker")
        let store = Self.makeUsageStore(settings: settings)
        let pane = ProvidersPane(settings: settings, store: store)

        let picker = pane._test_menuBarMetricPicker(for: .gemini)
        let ids = picker?.options.map(\.id) ?? []
        #expect(!ids.contains(MenuBarMetricPreference.tertiary.rawValue))
    }

    @Test
    func `provider detail plan row formats open router as balance`() {
        Self.withEnglishLocalization {
            let row = ProviderDetailView<EmptyView>.planRow(provider: .openrouter, planText: "Balance: $4.61")

            #expect(row?.label == "Balance")
            #expect(row?.value == "$4.61")
        }
    }

    @Test
    func `provider detail plan row formats moonshot as balance`() {
        Self.withEnglishLocalization {
            let row = ProviderDetailView<EmptyView>.planRow(provider: .moonshot, planText: "Balance: $49.58")

            #expect(row?.label == "Balance")
            #expect(row?.value == "$49.58")
        }
    }

    @Test
    func `provider detail plan row keeps plan label for non open router`() {
        Self.withEnglishLocalization {
            let row = ProviderDetailView<EmptyView>.planRow(provider: .codex, planText: "Pro")

            #expect(row?.label == "Plan")
            #expect(row?.value == "Pro")
        }
    }

    @Test
    func `provider detail renders metric status without progress`() {
        let metric = UsageMenuCardView.Model.Metric(
            id: "fixture",
            title: "Example quota",
            percent: 0,
            percentStyle: .left,
            statusText: "Unavailable",
            resetText: nil,
            detailText: nil,
            detailLeftText: nil,
            detailRightText: nil,
            pacePercent: nil,
            paceOnTop: false)

        #expect(ProviderDetailView<EmptyView>.metricInlinePresentation(metric) == .status("Unavailable"))
    }

    @Test
    func `provider detail renders ordinary metric progress`() {
        let metric = UsageMenuCardView.Model.Metric(
            id: "fixture",
            title: "Example quota",
            percent: 50,
            percentStyle: .left,
            resetText: nil,
            detailText: nil,
            detailLeftText: nil,
            detailRightText: nil,
            pacePercent: nil,
            paceOnTop: false)

        #expect(ProviderDetailView<EmptyView>.metricInlinePresentation(metric) == .progress)
    }

    @Test
    func `opencode manual cookie source hides cached browser trailing text`() {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-opencode-manual")
        let store = Self.makeUsageStore(settings: settings)
        settings.opencodeCookieSource = .manual
        CookieHeaderCache.store(provider: .opencode, cookieHeader: "auth=cache", sourceLabel: "Chrome")
        defer { CookieHeaderCache.clear(provider: .opencode) }

        let pane = ProvidersPane(settings: settings, store: store)
        let picker = pane._test_settingsPickers(for: .opencode).first { $0.id == "opencode-cookie-source" }

        #expect(picker?.dynamicSubtitle?() == "Paste a Cookie header captured from the billing page.")
        #expect(picker?.trailingText?() == nil)
    }

    @Test
    func `opencode go manual cookie source hides cached browser trailing text`() {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-opencodego-manual")
        let store = Self.makeUsageStore(settings: settings)
        settings.opencodegoCookieSource = .manual
        CookieHeaderCache.store(provider: .opencodego, cookieHeader: "auth=cache", sourceLabel: "Chrome")
        defer { CookieHeaderCache.clear(provider: .opencodego) }

        let pane = ProvidersPane(settings: settings, store: store)
        let picker = pane._test_settingsPickers(for: .opencodego).first { $0.id == "opencodego-cookie-source" }

        #expect(picker?.dynamicSubtitle?() == "Paste a Cookie header captured from the billing page.")
        #expect(picker?.trailingText?() == nil)
    }

    @Test
    func `codex providers pane uses managed account fallback instead of ambient account`() throws {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-codex-managed-fallback")
        let ambientHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        let managedHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: ambientHome)
            try? FileManager.default.removeItem(at: managedHome)
        }

        try Self.writeCodexAuthFile(homeURL: ambientHome, email: "ambient@example.com", plan: "plus")
        try Self.writeCodexAuthFile(homeURL: managedHome, email: "managed@example.com", plan: "enterprise")
        let managedAccountID = UUID()
        settings.codexActiveSource = .managedAccount(id: managedAccountID)
        settings._test_activeManagedCodexAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "managed@example.com",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)

        let store = UsageStore(
            fetcher: UsageFetcher(environment: ["CODEX_HOME": ambientHome.path]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(usedPercent: 34, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
                updatedAt: Date(),
                identity: nil),
            provider: .codex)

        let pane = ProvidersPane(settings: settings, store: store)
        let model = pane._test_menuCardModel(for: .codex)

        #expect(model.email == "managed@example.com")
        #expect(model.planText == "Enterprise")
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

    private static func withEnglishLocalization(perform body: () -> Void) {
        CodexBarLocalizationOverride.$appLanguage.withValue("en", operation: body)
    }

    private static func writeCodexAuthFile(homeURL: URL, email: String, plan: String) throws {
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let auth = [
            "tokens": [
                "accessToken": "access-token",
                "refreshToken": "refresh-token",
                "idToken": Self.fakeJWT(email: email, plan: plan),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: auth)
        try data.write(to: homeURL.appendingPathComponent("auth.json"))
    }

    private static func fakeJWT(email: String, plan: String) -> String {
        let header = (try? JSONSerialization.data(withJSONObject: ["alg": "none"])) ?? Data()
        let payload = (try? JSONSerialization.data(withJSONObject: [
            "email": email,
            "chatgpt_plan_type": plan,
        ])) ?? Data()

        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }

        return "\(base64URL(header)).\(base64URL(payload))."
    }
}
