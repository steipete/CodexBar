import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite
struct UsageStorePlanUtilizationClaudeIdentityTests {
    @MainActor
    @Test
    func planHistorySelectsConfiguredTokenAccountBucket() throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        store.settings.addTokenAccount(provider: .claude, label: "Alice", token: "alice-token")
        store.settings.addTokenAccount(provider: .claude, label: "Bob", token: "bob-token")

        let accounts = store.settings.tokenAccounts(for: .claude)
        let alice = try #require(accounts.first)
        let bob = try #require(accounts.last)
        let aliceKey = try #require(
            UsageStore._planUtilizationTokenAccountKeyForTesting(
                provider: .claude,
                account: alice))
        let bobKey = try #require(
            UsageStore._planUtilizationTokenAccountKeyForTesting(
                provider: .claude,
                account: bob))

        let aliceSample = makePlanSample(at: Date(timeIntervalSince1970: 1_700_000_000), primary: 15, secondary: 25)
        let bobSample = makePlanSample(at: Date(timeIntervalSince1970: 1_700_086_400), primary: 45, secondary: 55)

        store.planUtilizationHistory[.claude] = PlanUtilizationHistoryBuckets(
            accounts: [
                aliceKey: [aliceSample],
                bobKey: [bobSample],
            ])

        store.settings.setActiveTokenAccountIndex(0, for: .claude)
        #expect(store.planUtilizationHistory(for: .claude) == [aliceSample])

        store.settings.setActiveTokenAccountIndex(1, for: .claude)
        #expect(store.planUtilizationHistory(for: .claude) == [bobSample])
    }

    @MainActor
    @Test
    func recordPlanHistoryWithoutExplicitAccountUsesSelectedTokenAccountBucket() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        store.settings.addTokenAccount(provider: .claude, label: "Alice", token: "alice-token")
        store.settings.addTokenAccount(provider: .claude, label: "Bob", token: "bob-token")
        store.settings.setActiveTokenAccountIndex(1, for: .claude)

        let aliceSnapshot = UsageStorePlanUtilizationTests.makeSnapshot(provider: .claude, email: "alice@example.com")
        let selectedTokenKey = try #require(
            store.settings.selectedTokenAccount(for: .claude).flatMap {
                UsageStore._planUtilizationTokenAccountKeyForTesting(provider: .claude, account: $0)
            })

        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: aliceSnapshot,
            now: Date(timeIntervalSince1970: 1_700_000_000))

        let buckets = try #require(store.planUtilizationHistory[.claude])
        #expect(buckets.accounts[selectedTokenKey]?.count == 1)
    }

    @MainActor
    @Test
    func applySelectedOutcomeRecordsPlanHistoryForSelectedTokenAccount() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        store.settings.addTokenAccount(provider: .claude, label: "Alice", token: "alice-token")
        store.settings.addTokenAccount(provider: .claude, label: "Bob", token: "bob-token")
        store.settings.setActiveTokenAccountIndex(1, for: .claude)

        let selectedAccount = try #require(store.settings.selectedTokenAccount(for: .claude))
        let selectedTokenKey = try #require(
            UsageStore._planUtilizationTokenAccountKeyForTesting(provider: .claude, account: selectedAccount))
        let snapshot = UsageStorePlanUtilizationTests.makeSnapshot(provider: .claude, email: "alice@example.com")
        let outcome = ProviderFetchOutcome(
            result: .success(
                ProviderFetchResult(
                    usage: snapshot,
                    credits: nil,
                    dashboard: nil,
                    sourceLabel: "test",
                    strategyID: "test",
                    strategyKind: .web)),
            attempts: [])

        await store.applySelectedOutcome(
            outcome,
            provider: .claude,
            account: selectedAccount,
            fallbackSnapshot: snapshot)

        let buckets = try #require(store.planUtilizationHistory[.claude])
        #expect(buckets.accounts[selectedTokenKey]?.count == 1)
    }

    @MainActor
    @Test
    func refreshingOtherTokenAccountsRecordsPlanHistoryAfterSelectedClaudeSnapshotResolves() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        store.settings.addTokenAccount(provider: .claude, label: "Alice", token: "alice-token")
        store.settings.addTokenAccount(provider: .claude, label: "Bob", token: "bob-token")
        store.settings.setActiveTokenAccountIndex(0, for: .claude)

        let accounts = store.settings.tokenAccounts(for: .claude)
        let alice = try #require(accounts.first)
        let bob = try #require(accounts.last)
        let bobKey = try #require(
            UsageStore._planUtilizationTokenAccountKeyForTesting(provider: .claude, account: bob))
        let aliceSnapshot = UsageStorePlanUtilizationTests.makeSnapshot(provider: .claude, email: "alice@example.com")
        let selectedOutcome = ProviderFetchOutcome(
            result: .success(
                ProviderFetchResult(
                    usage: aliceSnapshot,
                    credits: nil,
                    dashboard: nil,
                    sourceLabel: "test",
                    strategyID: "test",
                    strategyKind: .web)),
            attempts: [])
        store.refreshingProviders.insert(.claude)

        await store.applySelectedOutcome(
            selectedOutcome,
            provider: .claude,
            account: alice,
            fallbackSnapshot: aliceSnapshot)

        await store.recordFetchedTokenAccountPlanUtilizationHistory(
            provider: .claude,
            samples: [
                (account: bob, snapshot: UsageStorePlanUtilizationTests.makeSnapshot(
                    provider: .claude,
                    email: "bob@example.com")),
            ],
            selectedAccount: alice)

        let buckets = try #require(store.planUtilizationHistory[.claude])
        #expect(buckets.accounts[bobKey]?.count == 1)

        store.settings.setActiveTokenAccountIndex(1, for: .claude)
        #expect(store.planUtilizationHistory(for: .claude).count == 1)
    }

    @MainActor
    @Test
    func selectedClaudeTokenAccountAdoptsBootstrapHistoryBeforeSecondaryAccountsRecord() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        store.settings.addTokenAccount(provider: .claude, label: "Alice", token: "alice-token")
        store.settings.addTokenAccount(provider: .claude, label: "Bob", token: "bob-token")
        store.settings.setActiveTokenAccountIndex(0, for: .claude)

        let accounts = store.settings.tokenAccounts(for: .claude)
        let alice = try #require(accounts.first)
        let bob = try #require(accounts.last)
        let aliceKey = try #require(
            UsageStore._planUtilizationTokenAccountKeyForTesting(provider: .claude, account: alice))
        let bobKey = try #require(
            UsageStore._planUtilizationTokenAccountKeyForTesting(provider: .claude, account: bob))
        let bootstrapSample = makePlanSample(
            at: Date(timeIntervalSince1970: 1_700_000_000),
            primary: 15,
            secondary: 25)
        store.planUtilizationHistory[.claude] = PlanUtilizationHistoryBuckets(unscoped: [bootstrapSample])

        let aliceSnapshot = UsageStorePlanUtilizationTests.makeSnapshot(provider: .claude, email: "alice@example.com")
        let selectedOutcome = ProviderFetchOutcome(
            result: .success(
                ProviderFetchResult(
                    usage: aliceSnapshot,
                    credits: nil,
                    dashboard: nil,
                    sourceLabel: "test",
                    strategyID: "test",
                    strategyKind: .web)),
            attempts: [])
        store.refreshingProviders.insert(.claude)

        await store.applySelectedOutcome(
            selectedOutcome,
            provider: .claude,
            account: alice,
            fallbackSnapshot: aliceSnapshot)
        await store.recordFetchedTokenAccountPlanUtilizationHistory(
            provider: .claude,
            samples: [
                (account: bob, snapshot: UsageStorePlanUtilizationTests.makeSnapshot(
                    provider: .claude,
                    email: "bob@example.com")),
            ],
            selectedAccount: alice)

        let buckets = try #require(store.planUtilizationHistory[.claude])
        #expect(buckets.unscoped.isEmpty)
        #expect(buckets.accounts[aliceKey]?.contains(bootstrapSample) == true)
        #expect(buckets.accounts[bobKey]?.contains(bootstrapSample) != true)
    }

    @MainActor
    @Test
    func secondaryClaudeSamplesDoNotReplacePreferredStickyHistoryBucket() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        store.settings.addTokenAccount(provider: .claude, label: "Alice", token: "alice-token")
        store.settings.addTokenAccount(provider: .claude, label: "Bob", token: "bob-token")
        store.settings.setActiveTokenAccountIndex(0, for: .claude)

        let accounts = store.settings.tokenAccounts(for: .claude)
        let alice = try #require(accounts.first)
        let bob = try #require(accounts.last)
        let aliceKey = try #require(
            UsageStore._planUtilizationTokenAccountKeyForTesting(provider: .claude, account: alice))

        let aliceSnapshot = UsageStorePlanUtilizationTests.makeSnapshot(provider: .claude, email: "alice@example.com")
        let bobSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 1_700_003_600),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "bob@example.com",
                accountOrganization: nil,
                loginMethod: "plus"))
        let selectedOutcome = ProviderFetchOutcome(
            result: .success(
                ProviderFetchResult(
                    usage: aliceSnapshot,
                    credits: nil,
                    dashboard: nil,
                    sourceLabel: "test",
                    strategyID: "test",
                    strategyKind: .web)),
            attempts: [])
        store.refreshingProviders.insert(.claude)

        await store.applySelectedOutcome(
            selectedOutcome,
            provider: .claude,
            account: alice,
            fallbackSnapshot: aliceSnapshot)
        await store.recordFetchedTokenAccountPlanUtilizationHistory(
            provider: .claude,
            samples: [(account: bob, snapshot: bobSnapshot)],
            selectedAccount: alice)

        let buckets = try #require(store.planUtilizationHistory[.claude])
        #expect(buckets.preferredAccountKey == aliceKey)

        store.settings.removeTokenAccount(provider: .claude, accountID: alice.id)
        store.settings.removeTokenAccount(provider: .claude, accountID: bob.id)
        store._setSnapshotForTesting(
            UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date()),
            provider: .claude)

        let history = store.planUtilizationHistory(for: .claude)
        #expect(history.first?.primaryUsedPercent == 10)
        #expect(history.first?.secondaryUsedPercent == 20)
    }

    @MainActor
    @Test
    func secondaryClaudeSamplesDoNotConsumeAnonymousBootstrapHistoryWhenSelectedAccountFails() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        store.settings.addTokenAccount(provider: .claude, label: "Alice", token: "alice-token")
        store.settings.addTokenAccount(provider: .claude, label: "Bob", token: "bob-token")
        store.settings.setActiveTokenAccountIndex(0, for: .claude)

        let accounts = store.settings.tokenAccounts(for: .claude)
        let alice = try #require(accounts.first)
        let bob = try #require(accounts.last)
        let aliceKey = try #require(
            UsageStore._planUtilizationTokenAccountKeyForTesting(provider: .claude, account: alice))
        let bobKey = try #require(
            UsageStore._planUtilizationTokenAccountKeyForTesting(provider: .claude, account: bob))
        let bootstrapSample = makePlanSample(
            at: Date(timeIntervalSince1970: 1_700_000_000),
            primary: 15,
            secondary: 25)
        store.planUtilizationHistory[.claude] = PlanUtilizationHistoryBuckets(unscoped: [bootstrapSample])

        let bobSnapshot = UsageStorePlanUtilizationTests.makeSnapshot(provider: .claude, email: "bob@example.com")
        await store.recordFetchedTokenAccountPlanUtilizationHistory(
            provider: .claude,
            samples: [(account: bob, snapshot: bobSnapshot)],
            selectedAccount: alice)

        var buckets = try #require(store.planUtilizationHistory[.claude])
        #expect(buckets.unscoped == [bootstrapSample])
        #expect(buckets.accounts[bobKey]?.contains(bootstrapSample) != true)

        let aliceSnapshot = UsageStorePlanUtilizationTests.makeSnapshot(provider: .claude, email: "alice@example.com")
        let selectedOutcome = ProviderFetchOutcome(
            result: .success(
                ProviderFetchResult(
                    usage: aliceSnapshot,
                    credits: nil,
                    dashboard: nil,
                    sourceLabel: "test",
                    strategyID: "test",
                    strategyKind: .web)),
            attempts: [])
        store.refreshingProviders.insert(.claude)

        await store.applySelectedOutcome(
            selectedOutcome,
            provider: .claude,
            account: alice,
            fallbackSnapshot: aliceSnapshot)

        buckets = try #require(store.planUtilizationHistory[.claude])
        #expect(buckets.unscoped.isEmpty)
        #expect(buckets.accounts[aliceKey]?.contains(bootstrapSample) == true)
    }

    @MainActor
    @Test
    func claudePlanHistoryFallsBackToAnonymousBootstrapBucketBeforeFirstIdentity() {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let sample = makePlanSample(at: Date(timeIntervalSince1970: 1_700_000_000), primary: 20, secondary: 30)

        store.planUtilizationHistory[.claude] = PlanUtilizationHistoryBuckets(unscoped: [sample])

        #expect(store.planUtilizationHistory(for: .claude) == [sample])
    }

    @MainActor
    @Test
    func claudePlanHistoryIsHiddenWhileMainClaudeCardStillShowsRefreshing() {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let sample = makePlanSample(at: Date(timeIntervalSince1970: 1_700_000_000), primary: 10, secondary: 20)

        store.planUtilizationHistory[.claude] = PlanUtilizationHistoryBuckets(unscoped: [sample])
        store.refreshingProviders.insert(.claude)

        #expect(store.shouldShowPlanUtilizationRefreshingState(for: .claude))
        #expect(store.planUtilizationHistory(for: .claude).isEmpty)
    }

    @MainActor
    @Test
    func claudePlanHistoryStaysVisibleWhileRefreshFinishesAfterSnapshotAlreadyResolved() throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let snapshot = UsageStorePlanUtilizationTests.makeSnapshot(provider: .claude, email: "alice@example.com")
        let accountKey = try #require(
            UsageStore._planUtilizationAccountKeyForTesting(
                provider: .claude,
                snapshot: snapshot))
        let sample = makePlanSample(at: Date(timeIntervalSince1970: 1_700_000_000), primary: 10, secondary: 20)

        store.planUtilizationHistory[.claude] = PlanUtilizationHistoryBuckets(accounts: [accountKey: [sample]])
        store._setSnapshotForTesting(snapshot, provider: .claude)
        store.refreshingProviders.insert(.claude)

        #expect(store.shouldShowPlanUtilizationRefreshingState(for: .claude) == false)
        #expect(store.planUtilizationHistory(for: .claude) == [sample])
    }

    @MainActor
    @Test
    func planHistoryDoesNotReadLegacyIdentityBucketForTokenAccounts() throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        store.settings.addTokenAccount(provider: .claude, label: "Alice", token: "alice-token")

        let snapshot = UsageStorePlanUtilizationTests.makeSnapshot(provider: .claude, email: "alice@example.com")
        let legacyKey = try #require(
            UsageStore._planUtilizationAccountKeyForTesting(
                provider: .claude,
                snapshot: snapshot))
        let legacySample = makePlanSample(at: Date(timeIntervalSince1970: 1_700_000_000), primary: 10, secondary: 20)

        store.planUtilizationHistory[.claude] = PlanUtilizationHistoryBuckets(
            accounts: [legacyKey: [legacySample]])
        store._setSnapshotForTesting(snapshot, provider: .claude)

        #expect(store.planUtilizationHistory(for: .claude).isEmpty)
    }

    @MainActor
    @Test
    func recordPlanHistoryWithoutIdentityUsesAnonymousBootstrapBucketBeforeFirstIdentity() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 11, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 21, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 1_700_003_600))

        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_700_003_600))

        let buckets = try #require(store.planUtilizationHistory[.claude])
        #expect(buckets.unscoped.count == 1)
    }

    @MainActor
    @Test
    func recordPlanHistoryWhileMainClaudeCardStillShowsRefreshingSkipsWrite() async {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let snapshot = UsageStorePlanUtilizationTests.makeSnapshot(provider: .claude, email: "alice@example.com")
        store.refreshingProviders.insert(.claude)

        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(store.planUtilizationHistory[.claude] == nil)
    }

    @MainActor
    @Test
    func recordPlanHistoryWhileRefreshFinishesAfterSnapshotAlreadyResolvedStillWrites() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let snapshot = UsageStorePlanUtilizationTests.makeSnapshot(provider: .claude, email: "alice@example.com")
        let accountKey = try #require(
            UsageStore._planUtilizationAccountKeyForTesting(
                provider: .claude,
                snapshot: snapshot))
        store._setSnapshotForTesting(snapshot, provider: .claude)
        store.refreshingProviders.insert(.claude)

        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_700_000_000))

        let buckets = try #require(store.planUtilizationHistory[.claude])
        #expect(buckets.accounts[accountKey]?.count == 1)
    }

    @MainActor
    @Test
    func firstResolvedClaudeIdentityAdoptsAnonymousBootstrapHistory() throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let anonymousSample = makePlanSample(
            at: Date(timeIntervalSince1970: 1_700_000_000),
            primary: 15,
            secondary: 25)
        store.planUtilizationHistory[.claude] = PlanUtilizationHistoryBuckets(unscoped: [anonymousSample])

        let resolvedSnapshot = UsageStorePlanUtilizationTests.makeSnapshot(
            provider: .claude,
            email: "alice@example.com")
        let resolvedKey = try #require(
            UsageStore._planUtilizationAccountKeyForTesting(
                provider: .claude,
                snapshot: resolvedSnapshot))
        store._setSnapshotForTesting(resolvedSnapshot, provider: .claude)

        let history = store.planUtilizationHistory(for: .claude)

        #expect(history == [anonymousSample])
        let buckets = try #require(store.planUtilizationHistory[.claude])
        #expect(buckets.unscoped.isEmpty)
        #expect(buckets.accounts[resolvedKey] == [anonymousSample])
    }

    @MainActor
    @Test
    func claudeHistoryWithoutIdentityFallsBackToLastResolvedAccount() async {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let resolvedSnapshot = UsageStorePlanUtilizationTests.makeSnapshot(
            provider: .claude,
            email: "alice@example.com")
        store._setSnapshotForTesting(resolvedSnapshot, provider: .claude)

        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: resolvedSnapshot,
            now: Date(timeIntervalSince1970: 1_700_000_000))

        let identitylessSnapshot = UsageSnapshot(
            primary: resolvedSnapshot.primary,
            secondary: resolvedSnapshot.secondary,
            updatedAt: resolvedSnapshot.updatedAt)
        store._setSnapshotForTesting(identitylessSnapshot, provider: .claude)

        let history = store.planUtilizationHistory(for: .claude)

        #expect(history.count == 1)
        #expect(history.first?.primaryUsedPercent == 10)
        #expect(history.first?.secondaryUsedPercent == 20)
    }

    @MainActor
    @Test
    func claudeHistoryWithoutIdentityFallsBackToMostRecentKnownAccount() throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let aliceSnapshot = UsageStorePlanUtilizationTests.makeSnapshot(provider: .claude, email: "alice@example.com")
        let bobSnapshot = UsageStorePlanUtilizationTests.makeSnapshot(provider: .claude, email: "bob@example.com")
        let aliceKey = try #require(
            UsageStore._planUtilizationAccountKeyForTesting(
                provider: .claude,
                snapshot: aliceSnapshot))
        let bobKey = try #require(
            UsageStore._planUtilizationAccountKeyForTesting(
                provider: .claude,
                snapshot: bobSnapshot))
        let aliceSample = makePlanSample(at: Date(timeIntervalSince1970: 1_700_000_000), primary: 10, secondary: 20)
        let bobSample = makePlanSample(at: Date(timeIntervalSince1970: 1_700_086_400), primary: 40, secondary: 50)

        store.planUtilizationHistory[.claude] = PlanUtilizationHistoryBuckets(
            accounts: [
                aliceKey: [aliceSample],
                bobKey: [bobSample],
            ])
        store.planUtilizationHistory[.claude]?.preferredAccountKey = nil
        store._setSnapshotForTesting(
            UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date()),
            provider: .claude)

        #expect(store.planUtilizationHistory(for: .claude) == [bobSample])
    }
}
