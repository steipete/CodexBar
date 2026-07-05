import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct UsageStorePlanUtilizationClaudeIdentityBoundaryTests {
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

    @MainActor
    @Test
    func `established account accepts same owner after access token rotation`() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let owner = String(repeating: "a", count: 64)
        let accountIdentity = UsageStore._activeClaudeAccountIdentityForTesting("uuid-A")
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: self.snapshot(usedPercent: 30),
            claudeOAuthPersistentRefHash: "account-a-ref",
            claudeOAuthHistoryOwnerIdentifier: owner,
            claudeOAuthActiveAccountObservation: .stable(identity: accountIdentity),
            isClaudeOAuthSample: true,
            now: start)
        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: self.snapshot(usedPercent: 30),
            claudeOAuthPersistentRefHash: "account-a-ref",
            claudeOAuthHistoryOwnerIdentifier: owner,
            claudeOAuthActiveAccountObservation: .stable(identity: accountIdentity),
            isClaudeOAuthSample: true,
            now: start.addingTimeInterval(30 * 60))
        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: self.snapshot(usedPercent: 50),
            claudeOAuthHistoryOwnerIdentifier: owner,
            claudeOAuthKeychainCredentialMismatch: true,
            claudeOAuthActiveAccountObservation: .stable(identity: accountIdentity),
            isClaudeOAuthSample: true,
            now: start.addingTimeInterval(2 * 60 * 60))

        let key = try #require(
            UsageStore._claudeOAuthPlanUtilizationAccountKeyForTesting(historyOwnerIdentifier: owner))
        let buckets = try #require(store.planUtilizationHistory[.claude])
        #expect(findSeries(buckets.accounts[key] ?? [], name: .session, windowMinutes: 300)?
            .entries.map(\.usedPercent) == [30, 50])
    }

    @MainActor
    @Test
    func `first sighting without keychain match is quarantined`() async {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 90,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date())

        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: snapshot,
            claudeOAuthHistoryOwnerIdentifier: String(repeating: "s", count: 64),
            claudeOAuthKeychainCredentialMismatch: true,
            claudeOAuthActiveAccountObservation: .stable(
                identity: UsageStore._activeClaudeAccountIdentityForTesting("uuid-current")),
            isClaudeOAuthSample: true)

        #expect(UsageStore.loadClaudeOAuthAccountUuidMap(from: store.settings.userDefaults).isEmpty)
        #expect(store.planUtilizationHistory[.claude] == nil)
    }

    @MainActor
    @Test
    func `file backed owner records history when keychain comparison is unavailable`() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let owner = String(repeating: "e", count: 64)
        let key = try #require(
            UsageStore._claudeOAuthPlanUtilizationAccountKeyForTesting(historyOwnerIdentifier: owner))

        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: self.snapshot(usedPercent: 90),
            claudeOAuthHistoryOwnerIdentifier: owner,
            claudeOAuthKeychainCredentialUnavailable: true,
            claudeOAuthActiveAccountObservation: .stable(
                identity: UsageStore._activeClaudeAccountIdentityForTesting("uuid-current")),
            isClaudeOAuthSample: true)

        #expect(UsageStore.loadClaudeOAuthAccountUuidMap(from: store.settings.userDefaults).isEmpty)
        #expect(UsageStore.loadClaudeOAuthAccountBindingCandidateMap(
            from: store.settings.userDefaults).isEmpty)
        let buckets = try #require(store.planUtilizationHistory[.claude])
        #expect(findSeries(buckets.accounts[key] ?? [], name: .session, windowMinutes: 300)?
            .entries.map(\.usedPercent) == [90])
    }

    @MainActor
    @Test
    func `absent keychain still quarantines an owner bound to another account`() async {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let owner = String(repeating: "f", count: 64)
        store.persistClaudeOAuthAccountUuidMap([
            owner: UsageStore._activeClaudeAccountIdentityForTesting("uuid-A"),
        ])

        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: self.snapshot(usedPercent: 90),
            claudeOAuthHistoryOwnerIdentifier: owner,
            claudeOAuthKeychainCredentialAbsent: true,
            claudeOAuthActiveAccountObservation: .stable(
                identity: UsageStore._activeClaudeAccountIdentityForTesting("uuid-B")),
            isClaudeOAuthSample: true)

        #expect(store.planUtilizationHistory[.claude] == nil)
    }

    @MainActor
    @Test
    func `absent keychain records an unbound file owner`() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let owner = String(repeating: "b", count: 64)
        let key = try #require(
            UsageStore._claudeOAuthPlanUtilizationAccountKeyForTesting(historyOwnerIdentifier: owner))

        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: self.snapshot(usedPercent: 80),
            claudeOAuthHistoryOwnerIdentifier: owner,
            claudeOAuthKeychainCredentialAbsent: true,
            claudeOAuthActiveAccountObservation: .stable(
                identity: UsageStore._activeClaudeAccountIdentityForTesting("uuid-current")),
            isClaudeOAuthSample: true)

        let buckets = try #require(store.planUtilizationHistory[.claude])
        #expect(findSeries(buckets.accounts[key] ?? [], name: .session, windowMinutes: 300)?
            .entries.map(\.usedPercent) == [80])
    }

    @MainActor
    @Test
    func `account change during identity capture cannot bind or write history`() async {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 90,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date())

        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: snapshot,
            claudeOAuthPersistentRefHash: "account-a-ref",
            claudeOAuthHistoryOwnerIdentifier: String(repeating: "r", count: 64),
            claudeOAuthActiveAccountObservation: .changed,
            isClaudeOAuthSample: true)

        #expect(UsageStore.loadClaudeOAuthAccountUuidMap(from: store.settings.userDefaults).isEmpty)
        #expect(store.planUtilizationHistory[.claude] == nil)
    }

    @MainActor
    @Test
    func `missing active account identity preserves owner scoped history`() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let owner = String(repeating: "c", count: 64)
        let key = try #require(
            UsageStore._claudeOAuthPlanUtilizationAccountKeyForTesting(historyOwnerIdentifier: owner))
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 35,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date())

        await UsageStore.withActiveClaudeAccountUuidForTesting(nil) {
            await store.recordPlanUtilizationHistorySample(
                provider: .claude,
                snapshot: snapshot,
                claudeOAuthHistoryOwnerIdentifier: owner,
                claudeOAuthActiveAccountObservation: .stable(identity: nil),
                isClaudeOAuthSample: true)
        }

        let buckets = try #require(store.planUtilizationHistory[.claude])
        #expect(findSeries(buckets.accounts[key] ?? [], name: .session, windowMinutes: 300)?
            .entries.map(\.usedPercent) == [35])
    }

    @MainActor
    @Test
    func `explicit oauth credential ignores Claude Code account identity`() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let owner = String(repeating: "d", count: 64)
        let key = try #require(
            UsageStore._claudeOAuthPlanUtilizationAccountKeyForTesting(historyOwnerIdentifier: owner))
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 45,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date())

        await UsageStore.withActiveClaudeAccountUuidForTesting("claude-code-account") {
            await store.recordPlanUtilizationHistorySample(
                provider: .claude,
                snapshot: snapshot,
                claudeOAuthHistoryOwnerIdentifier: owner,
                claudeOAuthActiveAccountObservation: .changed,
                isClaudeOAuthSample: true)
        }

        let buckets = try #require(store.planUtilizationHistory[.claude])
        #expect(findSeries(buckets.accounts[key] ?? [], name: .session, windowMinutes: 300)?
            .entries.map(\.usedPercent) == [45])
        #expect(UsageStore.loadClaudeOAuthAccountUuidMap(from: store.settings.userDefaults).isEmpty)
    }

    @Test
    func `claude oauth history scope requires full auth fingerprint stability`() {
        let stablePersistentRefHash = UsageStore._stableClaudeKeychainPersistentRefHashForTesting(
            beforeFetchFingerprintToken: "stable-fingerprint",
            afterFetchFingerprintToken: "stable-fingerprint",
            beforeFetchPersistentRefHash: "stable-ref",
            afterFetchPersistentRefHash: "stable-ref")
        let changedFingerprintPersistentRefHash = UsageStore._stableClaudeKeychainPersistentRefHashForTesting(
            beforeFetchFingerprintToken: "before-fingerprint",
            afterFetchFingerprintToken: "after-fingerprint",
            beforeFetchPersistentRefHash: "stable-ref",
            afterFetchPersistentRefHash: "stable-ref")

        #expect(stablePersistentRefHash == "stable-ref")
        #expect(changedFingerprintPersistentRefHash == nil)
    }

    @Test
    func `credential change around account read invalidates the observation`() {
        let identityA = UsageStore._activeClaudeAccountIdentityForTesting("uuid-A")
        let identityB = UsageStore._activeClaudeAccountIdentityForTesting("uuid-B")
        let stable = UsageStore._claudeOAuthActiveAccountObservationForTesting(
            identityBeforeFetch: identityB,
            identityAfterFetch: identityB)
        let changed = UsageStore._claudeOAuthActiveAccountObservationForTesting(
            identityBeforeFetch: identityA,
            identityAfterFetch: identityB)
        let unstable = UsageStore._claudeOAuthActiveAccountObservationForTesting(
            identityBeforeFetch: identityB,
            identityAfterFetch: identityB,
            beforeFetchWasStable: false)

        #expect(stable == .stable(identity: identityB))
        #expect(changed == .changed)
        #expect(unstable == .changed)
    }

    private func snapshot(usedPercent: Double) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: usedPercent,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
    }
}
