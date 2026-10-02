import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct LangdockHistoryTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func `Langdock profiles cannot inherit or append unscoped history`() async {
        let store = Self.makeStore()
        let prior = PlanUtilizationHistoryBuckets(unscoped: [planSeries(
            name: .weekly,
            windowMinutes: 10080,
            entries: [planEntry(at: Self.now, usedPercent: 80, resetsAt: Self.now.addingTimeInterval(3600))])])
        store.planUtilizationHistory[.langdock] = prior
        let revision = store.planUtilizationHistoryRevision

        for profile in ["/synthetic/Edge/Profile 1", "/synthetic/Edge/Profile 2"] {
            store.settings.updateProviderConfig(provider: .langdock) { $0.langdockEdgeProfileID = profile }
            let snapshot = Self.snapshot(provider: .langdock, accountID: profile)
            store.snapshots[.langdock] = snapshot

            for loaded in [false, true] {
                store.planUtilizationHistoryLoaded = loaded
                #expect(!store.supportsPlanUtilizationHistory(for: .langdock))
                #expect(store.shouldHidePlanUtilizationMenuItem(for: .langdock))
                #expect(store.planUtilizationHistory(for: .langdock).isEmpty)
                #expect(store.planUtilizationHistorySelection(for: .langdock, readOnly: true).histories.isEmpty)
                #expect(store.planUtilizationHistorySelection(
                    for: .langdock, snapshotOverride: snapshot).histories.isEmpty)
                #expect(store.weeklyQuotaWindowResetObservations(for: .langdock).isEmpty)
                #expect(store.weeklyQuotaWindowResetObservations(
                    for: .langdock, historySelection: prior.selection(for: nil)).isEmpty)
            }

            await store.recordPlanUtilizationHistorySample(
                provider: .langdock, snapshot: snapshot, now: Self.now.addingTimeInterval(7200))
        }

        #expect(store.planUtilizationHistory[.langdock] == prior)
        #expect(store.planUtilizationHistoryRevision == revision)
        #expect(store.sessionLimitResetDetectorStates.isEmpty)
        #expect(store.weeklyLimitResetDetectorStates.isEmpty)
        #expect(store.settings.userDefaults.object(forKey: UsageStore.sessionLimitResetDetectorDefaultsKey) == nil)
        #expect(store.settings.userDefaults.object(forKey: "weeklyLimitResetDetectorStates") == nil)
    }

    @Test
    func `default history capability still records opted in provider usage`() async {
        let store = Self.makeStore()
        let snapshot = Self.snapshot(provider: .zai, accountID: "synthetic")
        store.snapshots[.zai] = snapshot

        #expect(store.supportsPlanUtilizationHistory(for: .zai))
        await store.recordPlanUtilizationHistorySample(provider: .zai, snapshot: snapshot, now: Self.now)

        let histories = store.planUtilizationHistory(for: .zai)
        #expect(histories.first { $0.name == .session }?.entries.last?.usedPercent == 20)
        #expect(histories.first { $0.name == .weekly }?.entries.last?.usedPercent == 10)
        #expect(!store.weeklyQuotaWindowResetObservations(for: .zai).isEmpty)
    }

    private static func makeStore() -> UsageStore {
        let settings = testSettingsStore(suiteName: "LangdockHistoryTests", userDefaults: InMemoryUserDefaults())
        settings.historicalTrackingEnabled = true
        return UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
    }

    private static func snapshot(provider: UsageProvider, accountID: String) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: self.now.addingTimeInterval(300 * 60),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 10,
                windowMinutes: 10080,
                resetsAt: self.now.addingTimeInterval(10080 * 60),
                resetDescription: nil),
            updatedAt: self.now,
            identity: ProviderIdentitySnapshot(
                providerID: provider.instanceID,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Edge profile",
                accountID: accountID))
    }
}
