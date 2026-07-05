import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct UsageStorePlanUtilizationClaudeIdentityBoundaryTests {
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
                isClaudeOAuthSample: true)
        }

        let buckets = try #require(store.planUtilizationHistory[.claude])
        #expect(findSeries(buckets.accounts[key] ?? [], name: .session, windowMinutes: 300)?
            .entries.map(\.usedPercent) == [35])
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
}
