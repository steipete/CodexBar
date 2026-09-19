import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct UsageStoreQuotaWindowHistoryTests {
    @Test
    func `live Codex reset history uses the workspace owner instead of email or stale preference`() throws {
        let store = try Self.makeStore()
        let snapshot = Self.snapshot(provider: .codex)
        store.snapshots[.codex] = snapshot
        store.settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "fixture@example.com",
            workspaceAccountID: "workspace-current",
            codexHomePath: "/synthetic/codex",
            observedAt: snapshot.updatedAt,
            identity: .providerAccount(id: "workspace-current"))
        defer { store.settings._test_liveSystemCodexAccount = nil }
        let currentKey = try #require(CodexHistoryOwnership
            .canonicalKey(for: .providerAccount(id: "workspace-current")))
        let otherKey = try #require(CodexHistoryOwnership.canonicalKey(for: .providerAccount(id: "workspace-other")))
        let current = Self.history(resetOffset: 3600)
        let other = Self.history(resetOffset: 7200)
        store.planUtilizationHistory[.codex] = .init(
            preferredAccountKey: otherKey,
            accounts: [currentKey: [current], otherKey: [other]])

        Self.expectLiveObservations(store, provider: .codex, history: current)
        let explicit = store.menuCardInput(
            for: .codex,
            context: .account(.init(
                snapshot: snapshot,
                historySelection: .init(accountKey: otherKey, histories: [other]))),
            now: snapshot.updatedAt)
        #expect(explicit.observedWeeklyResets == Self.observations(other))

        store.planUtilizationHistory[.codex]?.accounts.removeValue(forKey: currentKey)
        Self.expectLiveObservations(store, provider: .codex, history: nil)
    }

    @Test
    func `live Claude reset history uses the selected token account instead of snapshot email`() throws {
        let store = try Self.makeStore()
        store.settings.addTokenAccount(provider: .claude, label: "Selected", token: "fixture-token")
        store.settings.setActiveTokenAccountIndex(0, for: .claude)
        let account = try #require(store.settings.selectedTokenAccount(for: .claude))
        let key = try #require(UsageStore._planUtilizationTokenAccountKeyForTesting(
            provider: .claude,
            account: account))
        store.snapshots[.claude] = Self.snapshot(provider: .claude)
        let history = Self.history(resetOffset: 3600)
        store.planUtilizationHistory[.claude] = .init(
            preferredAccountKey: "unrelated",
            accounts: [key: [history], "unrelated": [Self.history(resetOffset: 7200)]])

        Self.expectLiveObservations(store, provider: .claude, history: history)
    }

    @Test
    func `live Claude OAuth history outranks an unrelated configured token and email`() throws {
        let store = try Self.makeStore()
        store.settings.addTokenAccount(provider: .claude, label: "Unrelated", token: "fixture-token")
        store.settings.setActiveTokenAccountIndex(0, for: .claude)
        let account = try #require(store.settings.selectedTokenAccount(for: .claude))
        let tokenKey = try #require(UsageStore._planUtilizationTokenAccountKeyForTesting(
            provider: .claude, account: account))
        let oauthKey = try #require(UsageStore._claudeOAuthPlanUtilizationAccountKeyForTesting(
            historyOwnerIdentifier: String(repeating: "a", count: 64)))
        store.snapshots[.claude] = Self.snapshot(provider: .claude)
        let history = Self.history(resetOffset: 3600)
        store.planUtilizationHistory[.claude] = .init(
            preferredAccountKey: oauthKey,
            accounts: [oauthKey: [history], tokenKey: [Self.history(resetOffset: 7200)]])

        Self.expectLiveObservations(store, provider: .claude, history: history)
    }

    @Test(arguments: [UsageProvider.codex, .claude])
    func `quota history reads do not migrate legacy buckets or adopt unscoped history`(
        provider: UsageProvider) throws
    {
        let store = try Self.makeStore()
        let snapshot = Self.snapshot(provider: provider)
        store.snapshots[provider.instanceID] = snapshot
        let legacyKey = if provider == .codex {
            UsageStore._codexLegacyPlanUtilizationEmailHashKeyForTesting(normalizedEmail: "fixture@example.com")
        } else {
            try #require(UsageStore._legacyClaudePlanUtilizationEmailAccountKeyForTesting(snapshot: snapshot))
        }
        store.planUtilizationHistory[provider.instanceID] = .init(
            preferredAccountKey: legacyKey,
            unscoped: [Self.history(resetOffset: 3600)],
            accounts: [legacyKey: [Self.history(resetOffset: 7200)]])

        Self.expectLiveObservations(store, provider: provider, history: nil)
    }

    private static func expectLiveObservations(
        _ store: UsageStore,
        provider: UsageProvider,
        history: PlanUtilizationSeriesHistory?)
    {
        let original = store.planUtilizationHistory
        let revision = store.planUtilizationHistoryRevision
        let expected = history.map(self.observations) ?? []
        for context in [UsageMenuCardContext.menu, .settings] {
            let input = store.menuCardInput(for: provider, context: context, now: self.now)
            #expect(input.observedWeeklyResets == expected)
        }
        #expect(store.planUtilizationHistory == original)
        #expect(store.planUtilizationHistoryRevision == revision)
    }

    private static func observations(_ history: PlanUtilizationSeriesHistory) -> [CostUsageQuotaResetObservation] {
        history.entries.compactMap { entry in
            entry.resetsAt.map { .init(capturedAt: entry.capturedAt, resetsAt: $0) }
        }
    }

    private static func makeStore() throws -> UsageStore {
        let suite = "UsageStoreQuotaWindowHistoryTests-\(UUID().uuidString)"
        let settings = testSettingsStore(suiteName: suite, userDefaults: InMemoryUserDefaults())
        let managedURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite)-accounts.json")
        try FileManagedCodexAccountStore(fileURL: managedURL).storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion, accounts: []))
        settings._test_managedCodexAccountStoreURL = managedURL
        settings.codexActiveSource = .liveSystem
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            planUtilizationHistoryStore: testPlanUtilizationHistoryStore(suiteName: suite),
            startupBehavior: .testing)
        store._cancelPlanUtilizationHistoryLoadForTesting()
        store.planUtilizationHistory = [:]
        return store
    }

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private static func snapshot(provider: UsageProvider) -> UsageSnapshot {
        UsageSnapshot(
            primary: nil,
            secondary: .init(
                usedPercent: 50,
                windowMinutes: 10080,
                resetsAt: self.now.addingTimeInterval(86400),
                resetDescription: nil),
            updatedAt: self.now,
            identity: .init(
                providerID: provider.instanceID,
                accountEmail: "fixture@example.com",
                accountOrganization: "fixture-organization",
                loginMethod: "plus"))
    }

    private static func history(resetOffset: TimeInterval) -> PlanUtilizationSeriesHistory {
        .init(name: .weekly, windowMinutes: 10080, entries: [
            .init(capturedAt: self.now, usedPercent: 50, resetsAt: self.now.addingTimeInterval(resetOffset)),
        ])
    }
}
