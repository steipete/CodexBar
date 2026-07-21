import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension SessionEquivalentForecastTests {
    @MainActor
    @Test
    func `generic account adoption migrates matching legacy pair identity`() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        store.settings.historicalTrackingEnabled = true
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 40,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(3 * 24 * 3600),
                resetDescription: nil),
            updatedAt: now)
        let identity = try #require(store.sessionEquivalentWindows(
            provider: .zai,
            snapshot: snapshot)?.historyIdentity)
        store.planUtilizationHistory[.zai] = PlanUtilizationHistoryBuckets(unscoped: [
            planSeries(
                name: .session,
                windowMinutes: 300,
                entries: [planEntry(at: now.addingTimeInterval(-3600), usedPercent: 10)]),
            planSeries(
                name: .weekly,
                windowMinutes: 10080,
                entries: [planEntry(at: now.addingTimeInterval(-3600), usedPercent: 30)]),
        ])
        let unrelatedKey = "cursor|\(UsageStore.planUtilizationUnscopedPreferredKey)"
        store.settings.userDefaults.set(
            [
                "zai|\(UsageStore.planUtilizationUnscopedPreferredKey)": identity,
                unrelatedKey: "unrelated-pair",
            ],
            forKey: UsageStore.legacySessionEquivalentHistoryIdentityDefaultsKey)
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "Zai test",
            token: "fixture",
            addedAt: 0,
            lastUsed: nil)
        let accountKey = try #require(UsageStore._planUtilizationTokenAccountKeyForTesting(
            provider: .zai,
            account: account))

        await store.recordPlanUtilizationHistorySample(
            provider: .zai,
            snapshot: snapshot,
            account: account,
            now: now)

        let migrated = try #require(store.planUtilizationHistory[.zai])
        #expect(migrated.unscoped.isEmpty)
        #expect(migrated.sessionEquivalentWindowPairIdentity(for: nil) == nil)
        #expect(migrated.sessionEquivalentWindowPairIdentity(for: accountKey) == identity)
        #expect(store.legacySessionEquivalentHistoryIdentity(provider: .zai, accountKey: nil) == identity)
        #expect(store.legacySessionEquivalentHistoryIdentity(provider: .cursor, accountKey: nil) == "unrelated-pair")
        let histories = migrated.histories(for: accountKey)
        #expect(findSeries(histories, name: .session, windowMinutes: 300)?.entries.map(\.usedPercent) == [10, 20])
        #expect(findSeries(histories, name: .weekly, windowMinutes: 10080)?.entries.map(\.usedPercent) == [30, 40])
    }

    @MainActor
    @Test
    func `generic account adoption preserves compatible session history across a legacy weekly change`() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        store.settings.historicalTrackingEnabled = true
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 40,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(3 * 24 * 3600),
                resetDescription: nil),
            updatedAt: now)
        let identity = try #require(store.sessionEquivalentWindows(
            provider: .zai,
            snapshot: snapshot)?.historyIdentity)
        let legacySnapshot = UsageSnapshot(
            primary: snapshot.primary,
            secondary: nil,
            tertiary: RateWindow(
                usedPercent: 30,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(3 * 24 * 3600),
                resetDescription: nil),
            updatedAt: now)
        let legacyIdentity = try #require(store.sessionEquivalentWindows(
            provider: .zai,
            snapshot: legacySnapshot)?.historyIdentity)
        #expect(legacyIdentity != identity)
        store.planUtilizationHistory[.zai] = PlanUtilizationHistoryBuckets(unscoped: [
            planSeries(
                name: .session,
                windowMinutes: 300,
                entries: [planEntry(at: now.addingTimeInterval(-3600), usedPercent: 10)]),
            planSeries(
                name: .weekly,
                windowMinutes: 10080,
                entries: [planEntry(at: now.addingTimeInterval(-3600), usedPercent: 30)]),
        ])
        store.settings.userDefaults.set(
            ["zai|\(UsageStore.planUtilizationUnscopedPreferredKey)": legacyIdentity],
            forKey: UsageStore.legacySessionEquivalentHistoryIdentityDefaultsKey)
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "Zai test",
            token: "fixture",
            addedAt: 0,
            lastUsed: nil)
        let accountKey = try #require(UsageStore._planUtilizationTokenAccountKeyForTesting(
            provider: .zai,
            account: account))

        await store.recordPlanUtilizationHistorySample(
            provider: .zai,
            snapshot: snapshot,
            account: account,
            now: now)

        let migrated = try #require(store.planUtilizationHistory[.zai])
        #expect(migrated.unscoped.isEmpty)
        #expect(migrated.sessionEquivalentWindowPairIdentity(for: nil) == nil)
        #expect(migrated.sessionEquivalentWindowPairIdentity(for: accountKey) == identity)
        #expect(store.legacySessionEquivalentHistoryIdentity(provider: .zai, accountKey: nil) == legacyIdentity)
        let histories = migrated.histories(for: accountKey)
        #expect(findSeries(histories, name: .session, windowMinutes: 300)?.entries.map(\.usedPercent) == [10, 20])
        #expect(findSeries(histories, name: .weekly, windowMinutes: 10080)?.entries.map(\.usedPercent) == [40])
    }
}
