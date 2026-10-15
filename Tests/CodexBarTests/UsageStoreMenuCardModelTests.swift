import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct UsageStoreMenuCardModelTests {
    @Test
    func `Claude menu separates stale usage from its error while settings retain the notice`() throws {
        try KeychainAccessGate.withTaskOverrideForTesting(false) {
            try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
                let store = self.makeStore()
                let snapshot = self.snapshot()
                let raw = ClaudeOAuthCredentialsError.missingAccessToken.localizedDescription
                store.snapshots[.claude] = snapshot
                store.errors[.claude] = raw

                let menu = store.menuCardModel(for: .claude, now: snapshot.updatedAt.addingTimeInterval(3600))
                #expect(menu.subtitleText == raw)
                #expect(menu.subtitleStyle == .error)
                #expect(menu.lastKnownUsageText?.hasPrefix("Showing last-known usage captured ") == true)
                #expect(!menu.subtitleText.contains("Showing last-known usage"))

                let settings = store.menuCardModel(for: .claude, context: .settings)
                let message = try #require(store.userFacingError(for: .claude))
                let pane = ProvidersPane(settings: store.settings, store: store)
                let preview = try #require(pane._test_providerErrorDisplay(for: .claude)?.preview)
                for text in [settings.subtitleText, message, preview] {
                    #expect(text.components(separatedBy: "Showing last-known usage").count == 2)
                }
                #expect(settings.lastKnownUsageText == nil)
            }
        }
    }

    @Test
    func `Claude error without a snapshot has no stale line`() {
        let store = self.makeStore()
        store.errors[.claude] = "Claude request failed"
        let model = store.menuCardModel(for: .claude)
        #expect(model.subtitleText == "Claude request failed")
        #expect(model.lastKnownUsageText == nil)
    }

    @Test
    func `non Claude errors retain their existing presentation`() {
        let store = self.makeStore()
        store.snapshots[.mistral] = self.snapshot()
        store.errors[.mistral] = "Mistral request failed"
        let model = store.menuCardModel(for: .mistral)
        #expect(model.subtitleText == store.userFacingError(for: .mistral))
        #expect(model.subtitleText == "Mistral request failed")
        #expect(model.lastKnownUsageText == nil)
    }

    @Test
    func `Claude account card keeps its own stale timestamp and error`() {
        let store = self.makeStore()
        let snapshot = self.snapshot()
        let model = store.menuCardModel(for: .claude, context: .account(.init(
            snapshot: snapshot,
            error: "Account request failed",
            lastKnownUsageCapturedAt: snapshot.updatedAt)))
        #expect(model.subtitleText == "Account request failed")
        #expect(model.lastKnownUsageText != nil)
    }

    @Test(arguments: [UsageProvider.claude, .grok])
    func `empty account context cannot borrow live usage identity or cost`(provider: UsageProvider) {
        let store = self.makeStore()
        store.settings.costUsageEnabled = true
        store.settings.hidePersonalInfo = false
        store.snapshots[provider.instanceID] = self.snapshot()
        store.errors[provider.instanceID] = "Live account failed"
        store._setTokenSnapshotForTesting(.init(
            sessionTokens: 100,
            sessionCostUSD: 2,
            last30DaysTokens: 100,
            last30DaysCostUSD: 2,
            daily: [],
            updatedAt: Date()), provider: provider)

        let model = store.menuCardModel(for: provider, context: .account(.init()))

        #expect(model.metrics.isEmpty)
        #expect(model.email.isEmpty)
        #expect(model.tokenUsage == nil)
        #expect(model.subtitleStyle != .error)
        #expect(!model.usesLiveSubtitle)
        #expect(store.menuCardModel(for: provider).subtitleStyle == .error)
    }

    @Test
    func `settings catalogue exposes globally gated extra usage without changing rendered preferences`() {
        let store = self.makeStore()
        store.settings.showOptionalCreditsAndExtraUsage = false
        store.snapshots[.claude] = self.snapshot().with(providerCost: ProviderCostSnapshot(
            used: 12, limit: 100, currencyCode: "USD", updatedAt: Date()))

        let displayed = store.menuCardModel(for: .claude, context: .settings)
        let catalogue = UsageMenuCardView.Model.make(store.menuCardInput(
            for: .claude, context: .settings, optionalUsageOverride: true))
        #expect(displayed.providerCost == nil)
        #expect(!displayed.metrics.contains { $0.id == "claude-extra-usage" })
        #expect(catalogue.usageItemDescriptors.contains { $0.id == .claudeExtraUsage && $0.requiresOptionalUsage })
        #expect(!store.settings.showOptionalCreditsAndExtraUsage)

        store.settings.setUsageItemVisible(false, itemID: .claudeExtraUsage, for: .claude)
        store.settings.showOptionalCreditsAndExtraUsage = true
        #expect(store.menuCardModel(for: .claude).providerCost == nil)
        #expect(store.menuCardModel(for: .claude, context: .settings).providerCost == nil)
        store.settings.setUsageItemVisible(true, itemID: .claudeExtraUsage, for: .claude)
        #expect(store.menuCardModel(for: .claude).providerCost != nil)
    }

    @Test
    func `settings keeps diagnostic cost policy separate from menu display choices`() {
        let store = self.makeStore()
        store.settings.costUsageEnabled = true
        store.settings.costSummaryDisplayStyle = .costSubmenu
        store.settings.costComparisonPeriodsEnabled = true
        store.settings.preferredCurrencyCode = "EUR"
        store.tokenRefreshInFlight.insert(.claude)
        store.snapshots[.claude] = self.snapshot()

        let menu = store.menuCardInput(for: .claude, context: .menu)
        let settings = store.menuCardInput(for: .claude, context: .settings)

        #expect(!menu.costSummaryInlineEnabled)
        #expect(settings.costSummaryInlineEnabled)
        #expect(menu.tokenCostMenuSectionEnabled)
        #expect(settings.tokenCostMenuSectionEnabled)
        #expect(menu.tokenCostIsRefreshing)
        #expect(!settings.tokenCostIsRefreshing)
        #expect(menu.costComparisonPeriodsEnabled)
        #expect(!settings.costComparisonPeriodsEnabled)
        #expect(menu.preferredCurrencyCode == "EUR")
        #expect(settings.preferredCurrencyCode == "auto")
        #expect(menu.usesLiveSubtitle)
        #expect(!settings.usesLiveSubtitle)
        #expect(settings.showsAllUsageLanes)
        #expect(!menu.showsAllUsageLanes)
    }

    @Test
    func `menu and settings share live quota presentation preferences`() {
        let store = self.makeStore()
        store.snapshots[.claude] = self.snapshot()
        store.settings.usageBarsShowUsed = true
        store.settings.resetTimesShowAbsolute = true
        store.settings.hidePersonalInfo = true
        store.settings.paceVisible = false
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let menu = store.menuCardModel(for: .claude, now: now)
        let settings = store.menuCardModel(for: .claude, context: .settings, now: now)

        #expect(menu.metrics.map(\.percent) == [25, 50])
        #expect(menu.metrics.map(\.percent) == settings.metrics.map(\.percent))
        #expect(menu.metrics.map(\.resetText) == settings.metrics.map(\.resetText))
        #expect(menu.email == settings.email)
        #expect(!menu.email.contains("fixture@example.com"))
    }

    @Test
    func `hidden lanes remain available to the settings visibility editor`() {
        let store = self.makeStore()
        store.snapshots[.claude] = self.snapshot()
        store.settings.setUsageItemVisible(false, itemID: .metric("primary"), for: .claude)

        let menu = store.menuCardModel(for: .claude)
        let settings = store.menuCardModel(for: .claude, context: .settings)
        let editor = UsageMenuCardView.Model.make(store.menuCardInput(for: .claude, context: .settings))

        #expect(!menu.metrics.contains { $0.id == "primary" })
        #expect(!settings.metrics.contains { $0.id == "primary" })
        #expect(editor.metrics.contains { $0.id == "primary" })
    }

    @Test
    func `shared card inputs preserve scoped weekly observations without changing history`() throws {
        let store = self.makeStore()
        let snapshot = self.snapshot()
        store.snapshots[.claude] = snapshot
        let accountKey = try #require(UsageStore.planUtilizationIdentityAccountKey(
            provider: .claude, snapshot: snapshot))
        let reset = try #require(snapshot.secondary?.resetsAt)
        let history = PlanUtilizationSeriesHistory(name: .weekly, windowMinutes: 10080, entries: [
            .init(capturedAt: snapshot.updatedAt, usedPercent: 50, resetsAt: reset),
        ])
        store.planUtilizationHistory[.claude] = PlanUtilizationHistoryBuckets(
            preferredAccountKey: accountKey,
            accounts: [accountKey: [history]])
        let original = store.planUtilizationHistory
        let revision = store.planUtilizationHistoryRevision
        let expected = [CostUsageQuotaResetObservation(capturedAt: snapshot.updatedAt, resetsAt: reset)]

        let menu = store.menuCardInput(for: .claude, context: .menu, now: snapshot.updatedAt)
        let settings = store.menuCardInput(for: .claude, context: .settings, now: snapshot.updatedAt)
        let empty = store.menuCardInput(for: .claude, context: .account(.init()), now: snapshot.updatedAt)
        let identityless = store.menuCardInput(
            for: .claude,
            context: .account(.init(snapshot: UsageSnapshot(
                primary: snapshot.primary,
                secondary: snapshot.secondary,
                updatedAt: snapshot.updatedAt))),
            now: snapshot.updatedAt)
        let selected = store.menuCardInput(
            for: .claude,
            context: .account(.init(historySelection: .init(accountKey: accountKey, histories: [history]))),
            now: snapshot.updatedAt)

        #expect(menu.observedWeeklyResets == expected)
        #expect(settings.observedWeeklyResets == expected)
        #expect(empty.observedWeeklyResets.isEmpty)
        #expect(identityless.observedWeeklyResets.isEmpty)
        #expect(selected.observedWeeklyResets == expected)
        #expect(store.planUtilizationHistory == original)
        #expect(store.planUtilizationHistoryRevision == revision)
    }

    private func makeStore() -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "UsageStoreMenuCardModelTests",
            userDefaults: InMemoryUserDefaults(),
            keychainAccessPolicy: .init(setDisabled: { _ in }, isExplicitlyDisabled: { false }))
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        store._cancelPlanUtilizationHistoryLoadForTesting()
        store.planUtilizationHistory = [:]
        return store
    }

    private func snapshot() -> UsageSnapshot {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return UsageSnapshot(
            primary: .init(
                usedPercent: 25,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: .init(
                usedPercent: 50,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(86400),
                resetDescription: nil),
            updatedAt: now,
            identity: .init(
                providerID: .claude,
                accountEmail: "fixture@example.com",
                accountOrganization: nil,
                loginMethod: "max"))
    }
}
