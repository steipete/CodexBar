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

    @MainActor
    @Test
    func `generic account adoption invalidates conflicting legacy source and target identities`() async throws {
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
        let sourceIdentity = try #require(store.sessionEquivalentWindows(
            provider: .zai,
            snapshot: snapshot)?.historyIdentity)
        let targetSnapshot = UsageSnapshot(
            primary: snapshot.primary,
            secondary: nil,
            tertiary: RateWindow(
                usedPercent: 35,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(3 * 24 * 3600),
                resetDescription: nil),
            updatedAt: now)
        let targetIdentity = try #require(store.sessionEquivalentWindows(
            provider: .zai,
            snapshot: targetSnapshot)?.historyIdentity)
        #expect(targetIdentity != sourceIdentity)
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "Zai test",
            token: "fixture",
            addedAt: 0,
            lastUsed: nil)
        let accountKey = try #require(UsageStore._planUtilizationTokenAccountKeyForTesting(
            provider: .zai,
            account: account))
        store.planUtilizationHistory[.zai] = PlanUtilizationHistoryBuckets(
            unscoped: [
                planSeries(
                    name: .session,
                    windowMinutes: 300,
                    entries: [planEntry(at: now.addingTimeInterval(-3600), usedPercent: 10)]),
                planSeries(
                    name: .weekly,
                    windowMinutes: 10080,
                    entries: [planEntry(at: now.addingTimeInterval(-3600), usedPercent: 30)]),
            ],
            accounts: [
                accountKey: [
                    planSeries(
                        name: .session,
                        windowMinutes: 300,
                        entries: [planEntry(at: now.addingTimeInterval(-1800), usedPercent: 15)]),
                    planSeries(
                        name: .weekly,
                        windowMinutes: 10080,
                        entries: [planEntry(at: now.addingTimeInterval(-1800), usedPercent: 35)]),
                ],
            ])
        store.settings.userDefaults.set(
            [
                "zai|\(UsageStore.planUtilizationUnscopedPreferredKey)": sourceIdentity,
                "zai|\(accountKey)": targetIdentity,
            ],
            forKey: UsageStore.legacySessionEquivalentHistoryIdentityDefaultsKey)

        await store.recordPlanUtilizationHistorySample(
            provider: .zai,
            snapshot: snapshot,
            account: account,
            now: now)

        let histories = try #require(store.planUtilizationHistory[.zai])
            .histories(for: accountKey)
        #expect(findSeries(histories, name: .session, windowMinutes: 300)?.entries.map(\.usedPercent) == [20])
        #expect(findSeries(histories, name: .weekly, windowMinutes: 10080)?.entries.map(\.usedPercent) == [40])
    }

    @MainActor
    @Test
    func `generic account adoption ignores stale target legacy identity without target history`() async throws {
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
        let sourceIdentity = try #require(store.sessionEquivalentWindows(
            provider: .zai,
            snapshot: snapshot)?.historyIdentity)
        let staleTargetSnapshot = UsageSnapshot(
            primary: snapshot.primary,
            secondary: nil,
            tertiary: RateWindow(
                usedPercent: 35,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(3 * 24 * 3600),
                resetDescription: nil),
            updatedAt: now)
        let staleTargetIdentity = try #require(store.sessionEquivalentWindows(
            provider: .zai,
            snapshot: staleTargetSnapshot)?.historyIdentity)
        #expect(staleTargetIdentity != sourceIdentity)
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "Zai test",
            token: "fixture",
            addedAt: 0,
            lastUsed: nil)
        let accountKey = try #require(UsageStore._planUtilizationTokenAccountKeyForTesting(
            provider: .zai,
            account: account))
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
            [
                "zai|\(UsageStore.planUtilizationUnscopedPreferredKey)": sourceIdentity,
                "zai|\(accountKey)": staleTargetIdentity,
            ],
            forKey: UsageStore.legacySessionEquivalentHistoryIdentityDefaultsKey)

        await store.recordPlanUtilizationHistorySample(
            provider: .zai,
            snapshot: snapshot,
            account: account,
            now: now)

        let migrated = try #require(store.planUtilizationHistory[.zai])
        #expect(migrated.unscoped.isEmpty)
        #expect(migrated.sessionEquivalentWindowPairIdentity(for: accountKey) == sourceIdentity)
        #expect(
            store.legacySessionEquivalentHistoryIdentity(provider: .zai, accountKey: accountKey) == staleTargetIdentity)
        let histories = migrated.histories(for: accountKey)
        #expect(findSeries(histories, name: .session, windowMinutes: 300)?.entries.map(\.usedPercent) == [10, 20])
        #expect(findSeries(histories, name: .weekly, windowMinutes: 10080)?.entries.map(\.usedPercent) == [30, 40])
    }

    @MainActor
    @Test
    func `persisted generic adoption retains matching and clears conflicting legacy history`() async throws {
        let identityStore = UsageStorePlanUtilizationTests.makeStore()
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
        let sourceIdentity = try #require(identityStore.sessionEquivalentWindows(
            provider: .zai,
            snapshot: snapshot)?.historyIdentity)
        let targetSnapshot = UsageSnapshot(
            primary: snapshot.primary,
            secondary: nil,
            tertiary: RateWindow(
                usedPercent: 35,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(3 * 24 * 3600),
                resetDescription: nil),
            updatedAt: now)
        let targetIdentity = try #require(identityStore.sessionEquivalentWindows(
            provider: .zai,
            snapshot: targetSnapshot)?.historyIdentity)
        #expect(targetIdentity != sourceIdentity)

        for targetHasHistory in [false, true] {
            let account = ProviderTokenAccount(
                id: UUID(),
                label: "Zai test",
                token: "fixture",
                addedAt: 0,
                lastUsed: nil)
            let accountKey = try #require(UsageStore._planUtilizationTokenAccountKeyForTesting(
                provider: .zai,
                account: account))
            var initialBuckets = PlanUtilizationHistoryBuckets(unscoped: [
                planSeries(
                    name: .session,
                    windowMinutes: 300,
                    entries: [planEntry(at: now.addingTimeInterval(-3600), usedPercent: 10)]),
                planSeries(
                    name: .weekly,
                    windowMinutes: 10080,
                    entries: [planEntry(at: now.addingTimeInterval(-3600), usedPercent: 30)]),
            ])
            if targetHasHistory {
                initialBuckets.setHistories([
                    planSeries(
                        name: .session,
                        windowMinutes: 300,
                        entries: [planEntry(at: now.addingTimeInterval(-1800), usedPercent: 15)]),
                    planSeries(
                        name: .weekly,
                        windowMinutes: 10080,
                        entries: [planEntry(at: now.addingTimeInterval(-1800), usedPercent: 35)]),
                ], for: accountKey)
            }

            let suiteName = "SessionEquivalentForecastMigrationTests-persisted-\(UUID().uuidString)"
            let historyStore = testPlanUtilizationHistoryStore(suiteName: suiteName)
            historyStore.save([.zai: initialBuckets])
            let settings = testSettingsStore(suiteName: suiteName)
            settings.historicalTrackingEnabled = true
            var legacyIdentities = [
                "zai|\(UsageStore.planUtilizationUnscopedPreferredKey)": sourceIdentity,
            ]
            if targetHasHistory {
                legacyIdentities["zai|\(accountKey)"] = targetIdentity
            }
            settings.userDefaults.set(
                legacyIdentities,
                forKey: UsageStore.legacySessionEquivalentHistoryIdentityDefaultsKey)
            let loadGate = PlanUtilizationHistoryLoadGate()
            let store = UsageStore(
                fetcher: UsageFetcher(),
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: settings,
                planUtilizationHistoryStore: historyStore,
                startupBehavior: .testing,
                planUtilizationHistoryLoadGateForTesting: loadGate)

            loadGate.open()
            await store._waitForPlanUtilizationHistoryLoadForTesting()
            #expect(store.planUtilizationHistory[.zai] == initialBuckets)

            await store.recordPlanUtilizationHistorySample(
                provider: .zai,
                snapshot: snapshot,
                account: account,
                now: now)

            let inMemory = try #require(store.planUtilizationHistory[.zai])
            let histories = inMemory.histories(for: accountKey)
            #expect(inMemory.unscoped.isEmpty)
            if targetHasHistory {
                #expect(findSeries(histories, name: .session, windowMinutes: 300)?.entries.map(\.usedPercent) == [20])
                #expect(findSeries(histories, name: .weekly, windowMinutes: 10080)?.entries.map(\.usedPercent) == [40])
            } else {
                #expect(inMemory.sessionEquivalentWindowPairIdentity(for: accountKey) == sourceIdentity)
                #expect(findSeries(histories, name: .session, windowMinutes: 300)?.entries.map(\.usedPercent) == [
                    10,
                    20,
                ])
                #expect(findSeries(histories, name: .weekly, windowMinutes: 10080)?.entries.map(\.usedPercent) == [
                    30,
                    40,
                ])
            }

            var persisted: PlanUtilizationHistoryBuckets?
            for _ in 0..<100 {
                persisted = historyStore.load()[.zai]
                if persisted == inMemory {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(persisted == inMemory)
        }
    }
}
