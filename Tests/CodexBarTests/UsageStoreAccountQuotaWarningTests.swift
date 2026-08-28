import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct UsageStoreAccountQuotaWarningTests {
    @MainActor
    private final class NotifierSpy: SessionQuotaNotifying {
        private(set) var quotaWarnings: [QuotaWarningEvent] = []

        func post(transition _: SessionQuotaTransition, provider _: UsageProvider, badge _: NSNumber?) {}

        func postQuotaWarning(
            event: QuotaWarningEvent,
            provider _: UsageProvider,
            soundEnabled _: Bool,
            onScreenAlertEnabled _: Bool)
        {
            self.quotaWarnings.append(event)
        }
    }

    @Test
    func `ordinary refresh keeps selected token account warning episodes independent`() async {
        let settings = testSettingsStore(
            suiteName: "UsageStoreAccountQuotaWarningTests-selected-account",
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.quotaWarningNotificationsEnabled = true
        settings.quotaWarningThresholds = [50]
        settings.setQuotaWarningWindowEnabled(.session, enabled: true)
        settings.setQuotaWarningWindowEnabled(.weekly, enabled: false)
        settings.sessionQuotaNotificationsEnabled = false
        settings.predictivePaceWarningNotificationsEnabled = false
        settings.addTokenAccount(provider: .deepseek, label: "First", token: "fixture")
        settings.addTokenAccount(provider: .deepseek, label: "Second", token: "fixture")
        #expect(settings.tokenAccounts(for: .deepseek).map(\.label) == ["First", "Second"])

        let notifier = NotifierSpy()
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier,
            startupBehavior: .testing)
        let sequence = [
            (accountIndex: 0, usedPercent: 40.0),
            (accountIndex: 1, usedPercent: 40.0),
            (accountIndex: 0, usedPercent: 55.0),
            (accountIndex: 1, usedPercent: 30.0),
            (accountIndex: 0, usedPercent: 55.0),
            (accountIndex: 1, usedPercent: 55.0),
        ]

        for (step, observation) in sequence.enumerated() {
            settings.setActiveTokenAccountIndex(observation.accountIndex, for: .deepseek)
            let outcome = Self.outcome(
                usedPercent: observation.usedPercent,
                updatedAt: Date(timeIntervalSince1970: 1_780_000_000 + Double(step)))
            store._test_providerFetchOutcomeOverride = { _ in outcome }
            await store.refreshProvider(.deepseek, allowDisabled: true)
        }

        #expect(notifier.quotaWarnings.map(\.accountDisplayName) == ["First", "Second"])
        #expect(notifier.quotaWarnings.allSatisfy { $0.threshold == 50 })
    }

    @Test
    func `selected outcome keeps token account warning episodes independent`() async throws {
        let settings = testSettingsStore(
            suiteName: "UsageStoreAccountQuotaWarningTests-selected-outcome",
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.quotaWarningNotificationsEnabled = true
        settings.quotaWarningThresholds = [50]
        settings.setQuotaWarningWindowEnabled(.session, enabled: true)
        settings.setQuotaWarningWindowEnabled(.weekly, enabled: false)
        settings.sessionQuotaNotificationsEnabled = false
        settings.predictivePaceWarningNotificationsEnabled = false

        let accounts = try [
            ProviderTokenAccount(
                id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
                label: "First",
                token: "fixture",
                addedAt: 0,
                lastUsed: nil),
            ProviderTokenAccount(
                id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002")),
                label: "Second",
                token: "fixture",
                addedAt: 0,
                lastUsed: nil),
        ]
        let notifier = NotifierSpy()
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier,
            startupBehavior: .testing)
        let sequence = [
            (accountIndex: 0, usedPercent: 40.0),
            (accountIndex: 1, usedPercent: 40.0),
            (accountIndex: 0, usedPercent: 55.0),
            (accountIndex: 1, usedPercent: 30.0),
            (accountIndex: 0, usedPercent: 55.0),
            (accountIndex: 1, usedPercent: 55.0),
        ]

        for (step, observation) in sequence.enumerated() {
            await store.applySelectedOutcome(
                Self.outcome(
                    usedPercent: observation.usedPercent,
                    updatedAt: Date(timeIntervalSince1970: 1_780_000_000 + Double(step))),
                provider: .deepseek,
                account: accounts[observation.accountIndex],
                fallbackSnapshot: nil)
        }

        #expect(notifier.quotaWarnings.map(\.accountDisplayName) == ["First", "Second"])
        #expect(notifier.quotaWarnings.allSatisfy { $0.threshold == 50 })
    }

    private static func outcome(usedPercent: Double, updatedAt: Date) -> ProviderFetchOutcome {
        ProviderFetchOutcome(
            result: .success(ProviderFetchResult(
                usage: UsageSnapshot(
                    primary: RateWindow(
                        usedPercent: usedPercent,
                        windowMinutes: 300,
                        resetsAt: nil,
                        resetDescription: nil),
                    secondary: nil,
                    updatedAt: updatedAt),
                credits: nil,
                dashboard: nil,
                sourceLabel: "fixture",
                strategyID: "fixture.api-token",
                strategyKind: .apiToken)),
            attempts: [])
    }
}
