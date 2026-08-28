import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct QuotaLowHookAccountScopingTests {
    @Test
    func `quota_low crossing history is scoped per account`() {
        // Same provider/window/lane, different account discriminators must not share
        // history: one account's high usage must not overwrite or re-arm another's.
        let accountA = UsageStore.QuotaWarningStateKey(
            provider: .claude, window: .session, accountDiscriminator: "a@example.com")
        let accountB = UsageStore.QuotaWarningStateKey(
            provider: .claude, window: .session, accountDiscriminator: "b@example.com")
        #expect(accountA != accountB)

        var usage: [UsageStore.QuotaWarningStateKey: Double] = [:]
        usage[accountA] = 0.40
        usage[accountB] = 0.95
        // Account B's observation did not clobber account A's baseline.
        #expect(usage[accountA] == 0.40)
        #expect(usage[accountB] == 0.95)
    }

    @Test
    func `distinct windows and lanes stay independent for one account`() {
        let session = UsageStore.QuotaWarningStateKey(
            provider: .claude, window: .session, accountDiscriminator: "a@example.com")
        let weekly = UsageStore.QuotaWarningStateKey(
            provider: .claude, window: .weekly, accountDiscriminator: "a@example.com")
        let scoped = UsageStore.QuotaWarningStateKey(
            provider: .claude,
            window: .weekly,
            accountDiscriminator: "a@example.com",
            windowID: "claude-weekly-scoped-fable")
        #expect(Set([session, weekly, scoped]).count == 3)
    }

    @Test
    func `inactive hooks discard quota-low baselines`() {
        let store = self.makeStore(suiteName: "QuotaLowHookAccountScopingTests-inactive")
        let claude = UsageStore.QuotaWarningStateKey(
            provider: .claude, window: .session, accountDiscriminator: "account")
        let codex = UsageStore.QuotaWarningStateKey(
            provider: .codex, window: .session, accountDiscriminator: "account")
        store.quotaLowHookUsage = [claude: 0.4, codex: 0.5]

        store.clearQuotaLowHookUsage(provider: .claude)

        #expect(store.quotaLowHookUsage[claude] == nil)
        #expect(store.quotaLowHookUsage[codex] == 0.5)
    }

    @Test
    func `configuration revision discards quota-low baselines`() {
        let store = self.makeStore(suiteName: "QuotaLowHookAccountScopingTests-revision")
        let key = UsageStore.QuotaWarningStateKey(
            provider: .claude, window: .session, accountDiscriminator: "account")
        store.resetQuotaLowHookUsageIfConfigurationChanged()
        store.quotaLowHookUsage[key] = 0.4

        store.settings.setHooksEnabled(true)
        store.resetQuotaLowHookUsageIfConfigurationChanged()

        #expect(store.quotaLowHookUsage[key] == nil)
        #expect(store.quotaLowHookConfigRevision == store.settings.configRevision)
    }

    @Test
    func `vanished extra lanes discard quota-low baselines`() {
        let store = self.makeStore(suiteName: "QuotaLowHookAccountScopingTests-extra")
        let retained = UsageStore.QuotaWarningStateKey(
            provider: .claude,
            window: .weekly,
            accountDiscriminator: "account",
            windowID: "retained")
        let vanished = UsageStore.QuotaWarningStateKey(
            provider: .claude,
            window: .weekly,
            accountDiscriminator: "account",
            windowID: "vanished")
        store.quotaLowHookUsage = [retained: 0.4, vanished: 0.5]

        store.pruneQuotaLowHookUsage(
            provider: .claude,
            accountDiscriminator: "account",
            keepingExtraWindowIDs: ["retained"])

        #expect(store.quotaLowHookUsage[retained] == 0.4)
        #expect(store.quotaLowHookUsage[vanished] == nil)
    }

    private func makeStore(suiteName: String) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: testSettingsStore(suiteName: suiteName),
            environmentBase: [:])
    }
}
