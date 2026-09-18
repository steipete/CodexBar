import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct UsageStoreMenuCardModelTests {
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

    private func makeStore() -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "UsageStoreMenuCardModelTests",
            userDefaults: InMemoryUserDefaults())
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
