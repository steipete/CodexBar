import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct UsageStorePlanUtilizationClaudeIdentityTests {
    @MainActor
    @Test
    func `selected token account chooses matching bucket`() throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        store.settings.addTokenAccount(provider: .claude, label: "Alice", token: "alice-token")
        store.settings.addTokenAccount(provider: .claude, label: "Bob", token: "bob-token")
        let accounts = store.settings.tokenAccounts(for: .claude)
        let alice = try #require(accounts.first)
        let bob = try #require(accounts.last)
        let aliceKey = try #require(
            UsageStore._planUtilizationTokenAccountKeyForTesting(provider: .claude, account: alice))
        let bobKey = try #require(
            UsageStore._planUtilizationTokenAccountKeyForTesting(provider: .claude, account: bob))

        store.settings.setActiveTokenAccountIndex(0, for: .claude)
        store.planUtilizationHistory[.claude] = PlanUtilizationHistoryBuckets(accounts: [
            aliceKey: [planSeries(name: .weekly, windowMinutes: 10080, entries: [
                planEntry(at: Date(timeIntervalSince1970: 1_700_000_000), usedPercent: 20),
            ])],
            bobKey: [planSeries(name: .weekly, windowMinutes: 10080, entries: [
                planEntry(at: Date(timeIntervalSince1970: 1_700_086_400), usedPercent: 50),
            ])],
        ])

        #expect(store.planUtilizationHistory(for: .claude) == [
            planSeries(name: .weekly, windowMinutes: 10080, entries: [
                planEntry(at: Date(timeIntervalSince1970: 1_700_000_000), usedPercent: 20),
            ]),
        ])

        store.settings.setActiveTokenAccountIndex(1, for: .claude)
        #expect(store.planUtilizationHistory(for: .claude) == [
            planSeries(name: .weekly, windowMinutes: 10080, entries: [
                planEntry(at: Date(timeIntervalSince1970: 1_700_086_400), usedPercent: 50),
            ]),
        ])
    }

    @MainActor
    @Test
    func `fetched non selected accounts persist into separate claude buckets`() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        store.settings.addTokenAccount(provider: .claude, label: "Alice", token: "alice-token")
        store.settings.addTokenAccount(provider: .claude, label: "Bob", token: "bob-token")
        let accounts = store.settings.tokenAccounts(for: .claude)
        let alice = try #require(accounts.first)
        let bob = try #require(accounts.last)
        let bobKey = try #require(
            UsageStore._planUtilizationTokenAccountKeyForTesting(provider: .claude, account: bob))

        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 20, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 30, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "bob@example.com",
                accountOrganization: nil,
                loginMethod: "max"))

        await store.recordFetchedTokenAccountPlanUtilizationHistory(
            provider: .claude,
            samples: [(account: bob, snapshot: snapshot)],
            selectedAccount: alice)

        let buckets = try #require(store.planUtilizationHistory[.claude])
        let histories = try #require(buckets.accounts[bobKey])
        #expect(findSeries(histories, name: .session, windowMinutes: 300)?.entries.last?.usedPercent == 10)
        #expect(findSeries(histories, name: .weekly, windowMinutes: 10080)?.entries.last?.usedPercent == 20)
        #expect(findSeries(histories, name: .opus, windowMinutes: 10080)?.entries.last?.usedPercent == 30)
    }

    @MainActor
    @Test
    func `first resolved claude token account adopts unscoped history`() throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        store.settings.addTokenAccount(provider: .claude, label: "Alice", token: "alice-token")
        let alice = try #require(store.settings.tokenAccounts(for: .claude).first)
        let aliceKey = try #require(
            UsageStore._planUtilizationTokenAccountKeyForTesting(provider: .claude, account: alice))
        let bootstrap = planSeries(name: .session, windowMinutes: 300, entries: [
            planEntry(at: Date(timeIntervalSince1970: 1_700_000_000), usedPercent: 15),
        ])
        store.planUtilizationHistory[.claude] = PlanUtilizationHistoryBuckets(unscoped: [bootstrap])
        store.settings.setActiveTokenAccountIndex(0, for: .claude)

        let history = store.planUtilizationHistory(for: .claude)
        let buckets = try #require(store.planUtilizationHistory[.claude])

        #expect(history == [bootstrap])
        #expect(buckets.unscoped.isEmpty)
        #expect(buckets.accounts[aliceKey] == [bootstrap])
    }

    @MainActor
    @Test
    func `claude history without identity falls back to last resolved account`() async {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 20, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "alice@example.com",
                accountOrganization: nil,
                loginMethod: "max"))
        store._setSnapshotForTesting(snapshot, provider: .claude)

        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_700_000_000))

        let identitylessSnapshot = UsageSnapshot(
            primary: snapshot.primary,
            secondary: snapshot.secondary,
            updatedAt: snapshot.updatedAt)
        store._setSnapshotForTesting(identitylessSnapshot, provider: .claude)

        let history = store.planUtilizationHistory(for: .claude)
        #expect(findSeries(history, name: .session, windowMinutes: 300)?.entries.last?.usedPercent == 10)
        #expect(findSeries(history, name: .weekly, windowMinutes: 10080)?.entries.last?.usedPercent == 20)
    }
}
