import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct StatusItemBalanceDisplayTests {
    private func makeStatusBarForTesting() -> NSStatusBar {
        let env = ProcessInfo.processInfo.environment
        if env["GITHUB_ACTIONS"] == "true" || env["CI"] == "true" {
            return .system
        }
        return NSStatusBar()
    }

    @Test
    func `menu bar display text uses open router balance`() {
        let settings = self.makeSettings(
            suiteName: "StatusItemBalanceDisplayTests-openrouter-balance",
            provider: .openrouter)
        settings.setMenuBarMetricPreference(.automatic, for: .openrouter)
        let (store, controller) = self.makeStoreAndController(settings: settings)
        let snapshot = Self.openRouterSnapshot()

        store._setSnapshotForTesting(snapshot, provider: .openrouter)
        store._setErrorForTesting(nil, provider: .openrouter)

        let displayText = controller.menuBarDisplayText(for: .openrouter, snapshot: snapshot)

        #expect(displayText == "$12.34")
    }

    @Test
    func `menu bar display text respects open router primary metric preference`() {
        let settings = self.makeSettings(
            suiteName: "StatusItemBalanceDisplayTests-openrouter-primary-metric",
            provider: .openrouter)
        settings.setMenuBarMetricPreference(.primary, for: .openrouter)
        let (store, controller) = self.makeStoreAndController(settings: settings)
        let snapshot = Self.openRouterSnapshot()

        store._setSnapshotForTesting(snapshot, provider: .openrouter)
        store._setErrorForTesting(nil, provider: .openrouter)

        let displayText = controller.menuBarDisplayText(for: .openrouter, snapshot: snapshot)

        #expect(displayText == "25%")
    }

    @Test
    func `menu bar display text uses deepseek balance`() {
        let settings = self.makeSettings(
            suiteName: "StatusItemBalanceDisplayTests-deepseek-balance",
            provider: .deepseek)
        let (store, controller) = self.makeStoreAndController(settings: settings)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "$9.32 (Paid: $9.32 / Granted: $0.00)"),
            secondary: nil,
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .deepseek)
        store._setErrorForTesting(nil, provider: .deepseek)

        let displayText = controller.menuBarDisplayText(for: .deepseek, snapshot: snapshot)

        #expect(displayText == "$9.32")
    }

    @Test
    func `menu bar display text uses moonshot balance`() {
        let settings = self.makeSettings(
            suiteName: "StatusItemBalanceDisplayTests-moonshot-balance",
            provider: .moonshot)
        let (store, controller) = self.makeStoreAndController(settings: settings)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .moonshot,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Balance: $49.58 · $0.42 in deficit"))

        store._setSnapshotForTesting(snapshot, provider: .moonshot)
        store._setErrorForTesting(nil, provider: .moonshot)

        let displayText = controller.menuBarDisplayText(for: .moonshot, snapshot: snapshot)

        #expect(snapshot.primary == nil)
        #expect(displayText == "$49.58")
    }

    @Test
    func `menu bar display text uses mistral current month api spend`() {
        let settings = self.makeSettings(
            suiteName: "StatusItemBalanceDisplayTests-mistral-spend",
            provider: .mistral)
        let (store, controller) = self.makeStoreAndController(settings: settings)
        let snapshot = MistralUsageSnapshot(
            totalCost: 1.2345,
            currency: "EUR",
            currencySymbol: "€",
            totalInputTokens: 10000,
            totalOutputTokens: 5000,
            totalCachedTokens: 0,
            modelCount: 2,
            startDate: nil,
            endDate: nil,
            updatedAt: Date()).toUsageSnapshot()

        store._setSnapshotForTesting(snapshot, provider: .mistral)
        store._setErrorForTesting(nil, provider: .mistral)

        let displayText = controller.menuBarDisplayText(for: .mistral, snapshot: snapshot)

        #expect(snapshot.primary == nil)
        #expect(snapshot.identity?.loginMethod == "API spend: €1.2345 this month")
        #expect(displayText == "€1.2345")
    }

    @Test
    func `menu bar display text uses kimi k2 api key credits`() {
        let settings = self.makeSettings(
            suiteName: "StatusItemBalanceDisplayTests-kimik2-credits",
            provider: .kimik2)
        let (store, controller) = self.makeStoreAndController(settings: settings)
        let snapshot = KimiK2UsageSummary(
            consumed: 75,
            remaining: 1234.5,
            averageTokens: nil,
            updatedAt: Date()).toUsageSnapshot()

        store._setSnapshotForTesting(snapshot, provider: .kimik2)
        store._setErrorForTesting(nil, provider: .kimik2)

        let displayText = controller.menuBarDisplayText(for: .kimik2, snapshot: snapshot)

        #expect(snapshot.primary == nil)
        #expect(snapshot.identity?.loginMethod == "Credits: 1234.5 left")
        #expect(displayText == "1234.5")
    }

    @Test
    func `menu bar display text formats wafer requests remaining`() {
        let settings = self.makeSettings(
            suiteName: "StatusItemBalanceDisplayTests-wafer-requests",
            provider: .wafer)
        let (store, controller) = self.makeStoreAndController(settings: settings)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 12.3,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: "123/1000 requests"),
            secondary: nil,
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .wafer)
        store._setErrorForTesting(nil, provider: .wafer)

        let displayText = controller.menuBarDisplayText(for: .wafer, snapshot: snapshot)

        #expect(displayText == "877")
    }

    @Test
    func `menu bar display text returns nil when wafer snapshot or primary is nil`() {
        let settings = self.makeSettings(
            suiteName: "StatusItemBalanceDisplayTests-wafer-nil",
            provider: .wafer)
        let (store, controller) = self.makeStoreAndController(settings: settings)

        let displayText1 = controller.menuBarDisplayText(for: .wafer, snapshot: nil)
        #expect(displayText1 == nil)

        let snapshotWithNoPrimary = UsageSnapshot(
            primary: nil,
            secondary: nil,
            updatedAt: Date())
        let displayText2 = controller.menuBarDisplayText(for: .wafer, snapshot: snapshotWithNoPrimary)
        #expect(displayText2 == nil)
    }

    @Test
    func `kiro menu bar automatic uses credits left`() {
        let settings = self.makeSettings(
            suiteName: "StatusItemBalanceDisplayTests-kiro-automatic",
            provider: .kiro)
        settings.kiroMenuBarDisplayMode = .automatic
        let (store, controller) = self.makeStoreAndController(settings: settings)
        let snapshot = Self.kiroSnapshot()

        store._setSnapshotForTesting(snapshot, provider: .kiro)
        store._setErrorForTesting(nil, provider: .kiro)

        let displayText = controller.menuBarDisplayText(for: .kiro, snapshot: snapshot)

        #expect(displayText == "49.83")
    }

    @Test
    func `kiro menu bar credits and percent combines values`() {
        let settings = self.makeSettings(
            suiteName: "StatusItemBalanceDisplayTests-kiro-both",
            provider: .kiro)
        settings.kiroMenuBarDisplayMode = .creditsAndPercent
        let (store, controller) = self.makeStoreAndController(settings: settings)
        let snapshot = Self.kiroSnapshot()

        store._setSnapshotForTesting(snapshot, provider: .kiro)
        store._setErrorForTesting(nil, provider: .kiro)

        let displayText = controller.menuBarDisplayText(for: .kiro, snapshot: snapshot)

        #expect(displayText == "49.83 · 0%")
    }

    @Test
    func `kiro menu bar hidden suppresses text value`() {
        let settings = self.makeSettings(
            suiteName: "StatusItemBalanceDisplayTests-kiro-hidden",
            provider: .kiro)
        settings.kiroMenuBarDisplayMode = .hidden
        let (store, controller) = self.makeStoreAndController(settings: settings)
        let snapshot = Self.kiroSnapshot()

        store._setSnapshotForTesting(snapshot, provider: .kiro)
        store._setErrorForTesting(nil, provider: .kiro)

        let displayText = controller.menuBarDisplayText(for: .kiro, snapshot: snapshot)

        #expect(displayText == nil)
    }

    @Test
    func `kiro menu bar used and total formats credits`() {
        let settings = self.makeSettings(
            suiteName: "StatusItemBalanceDisplayTests-kiro-used-total",
            provider: .kiro)
        settings.kiroMenuBarDisplayMode = .usedAndTotal
        let (store, controller) = self.makeStoreAndController(settings: settings)
        let snapshot = Self.kiroSnapshot()

        store._setSnapshotForTesting(snapshot, provider: .kiro)
        store._setErrorForTesting(nil, provider: .kiro)

        let displayText = controller.menuBarDisplayText(for: .kiro, snapshot: snapshot)

        #expect(displayText == "0.17 / 50")
    }

    @Test
    func `kiro menu bar overage credits mode shows overage credits when exhausted`() {
        let settings = self.makeSettings(
            suiteName: "StatusItemBalanceDisplayTests-kiro-overage-credits",
            provider: .kiro)
        settings.kiroMenuBarDisplayMode = .overageCreditsWhenExhausted
        let (store, controller) = self.makeStoreAndController(settings: settings)
        let snapshot = Self.exhaustedKiroSnapshot()

        store._setSnapshotForTesting(snapshot, provider: .kiro)
        store._setErrorForTesting(nil, provider: .kiro)

        let displayText = controller.menuBarDisplayText(for: .kiro, snapshot: snapshot)

        #expect(displayText == "40.29 over")
    }

    @Test
    func `kiro menu bar overage cost mode shows cost when exhausted`() {
        let settings = self.makeSettings(
            suiteName: "StatusItemBalanceDisplayTests-kiro-overage-cost",
            provider: .kiro)
        settings.kiroMenuBarDisplayMode = .overageCostWhenExhausted
        let (store, controller) = self.makeStoreAndController(settings: settings)
        let snapshot = Self.exhaustedKiroSnapshot()

        store._setSnapshotForTesting(snapshot, provider: .kiro)
        store._setErrorForTesting(nil, provider: .kiro)

        let displayText = controller.menuBarDisplayText(for: .kiro, snapshot: snapshot)

        #expect(displayText == "$1.61 over")
    }

    @Test
    func `kiro menu bar overage credits and cost mode shows both when exhausted`() {
        let settings = self.makeSettings(
            suiteName: "StatusItemBalanceDisplayTests-kiro-overage-both",
            provider: .kiro)
        settings.kiroMenuBarDisplayMode = .overageCreditsAndCostWhenExhausted
        let (store, controller) = self.makeStoreAndController(settings: settings)
        let snapshot = Self.exhaustedKiroSnapshot()

        store._setSnapshotForTesting(snapshot, provider: .kiro)
        store._setErrorForTesting(nil, provider: .kiro)

        let displayText = controller.menuBarDisplayText(for: .kiro, snapshot: snapshot)

        #expect(displayText == "40.29 · $1.61")
    }

    @Test
    func `kiro menu bar overage mode keeps credits left before exhaustion`() {
        let settings = self.makeSettings(
            suiteName: "StatusItemBalanceDisplayTests-kiro-overage-not-exhausted",
            provider: .kiro)
        settings.kiroMenuBarDisplayMode = .overageCreditsAndCostWhenExhausted
        let (store, controller) = self.makeStoreAndController(settings: settings)
        let snapshot = Self.kiroSnapshot()

        store._setSnapshotForTesting(snapshot, provider: .kiro)
        store._setErrorForTesting(nil, provider: .kiro)

        let displayText = controller.menuBarDisplayText(for: .kiro, snapshot: snapshot)

        #expect(displayText == "49.83")
    }

    @Test
    func `kiro menu bar overage mode ignores disabled overage values`() {
        let settings = self.makeSettings(
            suiteName: "StatusItemBalanceDisplayTests-kiro-overage-disabled",
            provider: .kiro)
        settings.kiroMenuBarDisplayMode = .overageCreditsAndCostWhenExhausted
        let (store, controller) = self.makeStoreAndController(settings: settings)
        let snapshot = Self.exhaustedKiroSnapshot(overagesStatus: "Disabled")

        store._setSnapshotForTesting(snapshot, provider: .kiro)
        store._setErrorForTesting(nil, provider: .kiro)

        let displayText = controller.menuBarDisplayText(for: .kiro, snapshot: snapshot)

        #expect(displayText == "0")
    }

    @Test
    func `kiro managed plan display falls back to percent`() {
        let settings = self.makeSettings(
            suiteName: "StatusItemBalanceDisplayTests-kiro-managed",
            provider: .kiro)
        settings.kiroMenuBarDisplayMode = .automatic
        settings.usageBarsShowUsed = false
        let (store, controller) = self.makeStoreAndController(settings: settings)
        let snapshot = KiroUsageSnapshot(
            planName: "Q Developer Pro",
            creditsUsed: 0,
            creditsTotal: 0,
            creditsPercent: 0,
            bonusCreditsUsed: nil,
            bonusCreditsTotal: nil,
            bonusExpiryDays: nil,
            resetsAt: nil,
            updatedAt: Date()).toUsageSnapshot()

        store._setSnapshotForTesting(snapshot, provider: .kiro)
        store._setErrorForTesting(nil, provider: .kiro)

        let displayText = controller.menuBarDisplayText(for: .kiro, snapshot: snapshot)

        #expect(displayText == "100%")
    }

    @Test
    func `mistral primary window is nil even when billing end date is set`() {
        let endDate = Date(timeIntervalSinceNow: 3600)
        let snapshot = MistralUsageSnapshot(
            totalCost: 0.5,
            currency: "USD",
            currencySymbol: "$",
            totalInputTokens: 1000,
            totalOutputTokens: 500,
            totalCachedTokens: 0,
            modelCount: 1,
            startDate: nil,
            endDate: endDate,
            updatedAt: Date()).toUsageSnapshot()

        // Mistral doesn't expose a reset time — primary is always nil.
        #expect(snapshot.primary == nil)
    }

    @Test
    func `button title spacing only applies when image is present`() {
        #expect(StatusItemController.buttonTitle("42%", hasImage: true) == " 42%")
        #expect(StatusItemController.buttonTitle("42%", hasImage: false) == "42%")
        #expect(StatusItemController.buttonTitle(nil, hasImage: true).isEmpty)
        #expect(StatusItemController.buttonTitle("", hasImage: true).isEmpty)
    }

    private func makeSettings(suiteName: String, provider: UsageProvider) -> SettingsStore {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: suiteName),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = provider
        settings.menuBarDisplayMode = .both
        settings.usageBarsShowUsed = true

        let registry = ProviderRegistry.shared
        if let metadata = registry.metadata[provider] {
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: true)
        }
        return settings
    }

    private func makeStoreAndController(settings: SettingsStore) -> (UsageStore, StatusItemController) {
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        return (store, controller)
    }

    private static func openRouterSnapshot() -> UsageSnapshot {
        OpenRouterUsageSnapshot(
            totalCredits: 50,
            totalUsage: 37.66,
            balance: 12.34,
            usedPercent: 75.32,
            keyLimit: 20,
            keyUsage: 5,
            rateLimit: nil,
            updatedAt: Date()).toUsageSnapshot()
    }

    private static func kiroSnapshot() -> UsageSnapshot {
        KiroUsageSnapshot(
            planName: "KIRO FREE",
            accountEmail: "person@example.com",
            authMethod: "Google",
            creditsUsed: 0.17,
            creditsTotal: 50,
            creditsPercent: 0,
            bonusCreditsUsed: 45.53,
            bonusCreditsTotal: 2000,
            bonusExpiryDays: 19,
            overagesStatus: "Disabled",
            manageURL: "https://app.kiro.dev/account/usage",
            contextUsage: KiroContextUsageSnapshot(
                totalPercentUsed: 1.3,
                contextFilesPercent: 0.5,
                toolsPercent: 0.8,
                kiroResponsesPercent: 0,
                promptsPercent: 0),
            resetsAt: Date(),
            updatedAt: Date()).toUsageSnapshot()
    }

    private static func exhaustedKiroSnapshot(overagesStatus: String = "Enabled billed at $0.04 per request")
        -> UsageSnapshot
    {
        KiroUsageSnapshot(
            planName: "KIRO FREE",
            accountEmail: "person@example.com",
            authMethod: "Google",
            creditsUsed: 50,
            creditsTotal: 50,
            creditsPercent: 100,
            bonusCreditsUsed: nil,
            bonusCreditsTotal: nil,
            bonusExpiryDays: nil,
            overagesStatus: overagesStatus,
            overageCreditsUsed: 40.29,
            estimatedOverageCostUSD: 1.61,
            manageURL: "https://app.kiro.dev/account/usage",
            resetsAt: Date(),
            updatedAt: Date()).toUsageSnapshot()
    }
}
