import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct CommandCodeQuotaTransitionTests {
    @Test
    func `display keeps prior monthly window only during subscription enrichment failure`() throws {
        let plan = try #require(CommandCodePlanCatalog.plans.first { $0.monthlyCreditsUSD > 0 })
        let availableWithPlan = self.snapshot(remaining: 6, plan: plan)
        let missingSubscription = self.snapshot(
            remaining: 0,
            purchasedCredits: 5,
            plan: nil,
            subscriptionUnavailable: true)
        let freeTier = self.snapshot(remaining: 0, plan: nil)
        let freeTierWithPurchasedCredits = self.snapshot(remaining: 0, purchasedCredits: 5, plan: nil)

        #expect(missingSubscription.tertiary?.usedPercent == 0)
        #expect(freeTierWithPurchasedCredits.tertiary?.usedPercent == 0)

        let stabilized = UsageStore.commandCodeSnapshotResolvingDepletionOnEnrichmentFailure(
            current: missingSubscription,
            previous: availableWithPlan)
        #expect(stabilized.tertiary?.usedPercent == 100)

        let stabilizedAgain = UsageStore.commandCodeSnapshotResolvingDepletionOnEnrichmentFailure(
            current: missingSubscription,
            previous: stabilized)
        #expect(stabilizedAgain.tertiary?.usedPercent == 100)

        let startupFailure = UsageStore.commandCodeSnapshotResolvingDepletionOnEnrichmentFailure(
            current: missingSubscription,
            previous: nil)
        #expect(startupFailure.tertiary?.usedPercent == 0)

        let freeTierFailure = UsageStore.commandCodeSnapshotResolvingDepletionOnEnrichmentFailure(
            current: missingSubscription,
            previous: freeTierWithPurchasedCredits)
        #expect(freeTierFailure.tertiary?.usedPercent == 0)

        let validFreeTier = UsageStore.commandCodeSnapshotResolvingDepletionOnEnrichmentFailure(
            current: freeTier,
            previous: availableWithPlan)
        #expect(validFreeTier.tertiary == nil)
    }

    @Test
    func `subscription enrichment failure preserves rolling windows`() throws {
        let plan = try #require(CommandCodePlanCatalog.plans.first { $0.monthlyCreditsUSD > 0 })
        let rolling = RateWindow(
            usedPercent: 25,
            windowMinutes: 5 * 60,
            resetsAt: Date(timeIntervalSince1970: 1_780_000_000),
            resetDescription: nil)
        let availableWithPlan = self.snapshot(remaining: 6, plan: plan)
        let missingSubscription = self.snapshot(
            remaining: 0,
            purchasedCredits: 5,
            plan: nil,
            subscriptionUnavailable: true,
            fiveHourWindow: rolling)

        let stabilized = UsageStore.commandCodeSnapshotResolvingDepletionOnEnrichmentFailure(
            current: missingSubscription,
            previous: availableWithPlan)

        #expect(stabilized.primary == rolling)
        #expect(stabilized.tertiary?.usedPercent == 100)
    }

    @Test
    func `depleted notification does not refire across missing subscription window`() throws {
        let settings = self.makeSettings(suiteName: "CommandCodeDepletedNoRefire")
        settings.sessionQuotaNotificationsEnabled = true
        let notifier = NotifierSpy()
        let store = self.makeStore(settings: settings, notifier: notifier)
        let plan = try #require(CommandCodePlanCatalog.plans.first { $0.monthlyCreditsUSD > 0 })
        let availableWithPlan = self.snapshot(
            remaining: 6,
            plan: plan,
            fiveHourWindow: self.rollingWindow(usedPercent: 0))
        let depletedWithPlan = self.snapshot(
            remaining: 0,
            plan: plan,
            fiveHourWindow: self.rollingWindow(usedPercent: 100))
        let missingSubscription = self.snapshot(
            remaining: 0,
            purchasedCredits: 5,
            plan: nil,
            subscriptionUnavailable: true,
            fiveHourWindow: self.rollingWindow(usedPercent: 100))

        store.handleSessionQuotaTransition(provider: .commandcode, snapshot: availableWithPlan)
        #expect(notifier.posts.isEmpty)

        store.handleSessionQuotaTransition(provider: .commandcode, snapshot: depletedWithPlan)
        let stabilizedFailure = UsageStore.commandCodeSnapshotResolvingDepletionOnEnrichmentFailure(
            current: missingSubscription,
            previous: depletedWithPlan)
        store.handleSessionQuotaTransition(provider: .commandcode, snapshot: stabilizedFailure)
        let repeatedFailure = UsageStore.commandCodeSnapshotResolvingDepletionOnEnrichmentFailure(
            current: missingSubscription,
            previous: stabilizedFailure)
        store.handleSessionQuotaTransition(provider: .commandcode, snapshot: repeatedFailure)
        store.handleSessionQuotaTransition(provider: .commandcode, snapshot: depletedWithPlan)

        #expect(notifier.posts.count(where: { $0.transition == .depleted }) == 1)

        store.handleSessionQuotaTransition(provider: .commandcode, snapshot: availableWithPlan)
        store.handleSessionQuotaTransition(provider: .commandcode, snapshot: depletedWithPlan)
        #expect(notifier.posts.count(where: { $0.transition == .depleted }) == 2)
    }

    @Test
    func `quota warning does not refire across missing subscription window`() throws {
        let settings = self.makeSettings(suiteName: "CommandCodeWarningNoRefire")
        settings.quotaWarningNotificationsEnabled = true
        settings.quotaWarningThresholds = [50]
        let notifier = NotifierSpy()
        let store = self.makeStore(settings: settings, notifier: notifier)
        let plan = try #require(CommandCodePlanCatalog.plans.first { $0.monthlyCreditsUSD > 0 })

        let availableWithPlan = self.snapshot(
            remaining: 6,
            plan: plan,
            fiveHourWindow: self.rollingWindow(usedPercent: 40))
        let warningWithPlan = self.snapshot(
            remaining: 4,
            plan: plan,
            fiveHourWindow: self.rollingWindow(usedPercent: 60))
        store.handleQuotaWarningTransitions(provider: .commandcode, snapshot: availableWithPlan)
        store.handleQuotaWarningTransitions(provider: .commandcode, snapshot: warningWithPlan)
        let missingSubscription = self.snapshot(
            remaining: 0,
            purchasedCredits: 5,
            plan: nil,
            subscriptionUnavailable: true,
            fiveHourWindow: self.rollingWindow(usedPercent: 60))
        let stabilizedFailure = UsageStore.commandCodeSnapshotResolvingDepletionOnEnrichmentFailure(
            current: missingSubscription,
            previous: warningWithPlan)
        store.handleQuotaWarningTransitions(provider: .commandcode, snapshot: stabilizedFailure)
        let repeatedFailure = UsageStore.commandCodeSnapshotResolvingDepletionOnEnrichmentFailure(
            current: missingSubscription,
            previous: stabilizedFailure)
        store.handleQuotaWarningTransitions(provider: .commandcode, snapshot: repeatedFailure)
        store.handleQuotaWarningTransitions(provider: .commandcode, snapshot: warningWithPlan)

        #expect(notifier.quotaWarningPosts.count == 1)

        store.handleQuotaWarningTransitions(provider: .commandcode, snapshot: availableWithPlan)
        store.handleQuotaWarningTransitions(provider: .commandcode, snapshot: warningWithPlan)
        #expect(notifier.quotaWarningPosts.count == 2)
    }

    private func makeSettings(suiteName: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suiteName),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        return settings
    }

    private func makeStore(settings: SettingsStore, notifier: NotifierSpy) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier)
    }

    private func snapshot(
        remaining: Double,
        purchasedCredits: Double = 0,
        plan: CommandCodePlanCatalog.Plan?,
        subscriptionUnavailable: Bool = false,
        fiveHourWindow: RateWindow? = nil) -> UsageSnapshot
    {
        CommandCodeUsageSnapshot(
            monthlyCreditsRemaining: remaining,
            purchasedCredits: purchasedCredits,
            premiumMonthlyCredits: 0,
            opensourceMonthlyCredits: 0,
            fiveHourWindow: fiveHourWindow,
            plan: plan,
            billingPeriodEnd: nil,
            subscriptionStatus: plan == nil ? nil : "active",
            subscriptionEnrichmentUnavailable: subscriptionUnavailable)
            .toUsageSnapshot()
    }

    private func rollingWindow(usedPercent: Double) -> RateWindow {
        RateWindow(
            usedPercent: usedPercent,
            windowMinutes: 5 * 60,
            resetsAt: Date(timeIntervalSince1970: 1_780_000_000),
            resetDescription: nil)
    }

    private final class NotifierSpy: SessionQuotaNotifying {
        private(set) var posts: [(transition: SessionQuotaTransition, provider: UsageProvider)] = []
        private(set) var quotaWarningPosts: [QuotaWarningEvent] = []

        func post(transition: SessionQuotaTransition, provider: UsageProvider, badge _: NSNumber?) {
            self.posts.append((transition, provider))
        }

        func postQuotaWarning(
            event: QuotaWarningEvent,
            provider _: UsageProvider,
            soundEnabled _: Bool,
            onScreenAlertEnabled _: Bool)
        {
            self.quotaWarningPosts.append(event)
        }
    }
}
