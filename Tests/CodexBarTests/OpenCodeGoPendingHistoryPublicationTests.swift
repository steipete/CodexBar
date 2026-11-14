import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct OpenCodeGoPendingHistoryPublicationTests {
    @Test
    func `pending local history does not publish a confirmed empty cost snapshot`() async throws {
        let settings = testSettingsStore(
            suiteName: "OpenCodeGoPendingHistoryPublicationTests", userDefaults: InMemoryUserDefaults())
        settings.costUsageEnabled = true
        settings.refreshFrequency = .manual
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let now = Date()
        settings.costUsageBucketTimeZoneIdentifier = "UTC"
        let day = String(ISO8601DateFormatter().string(from: now).prefix(10))
        let entry = CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 100,
            costUSD: 3,
            modelsUsed: ["fixture-model"],
            modelBreakdowns: nil)
        let local = try OpenCodeGoUsageFetcher.parseAPIUsage(
            text: #"{"usage":{"rolling":{"percent":40}}}"#, now: now).withDaily([entry])
        store.publishProviderDerivedTokenSnapshot(from: local.toUsageSnapshot(), for: .opencodego)
        let before = try #require(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .opencodego))
        #expect(before.snapshot?.last30DaysCostUSD == 3)
        var remote = try OpenCodeGoUsageFetcher.parseAPIUsage(
            text: #"{"usage":{"rolling":{"percent":50}}}"#, now: now)
        remote.localHistoryPending = true
        store.installProviderDerivedTokenSnapshot(from: remote.toUsageSnapshot(), for: .opencodego)
        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .opencodego)?.snapshot == before.snapshot)
        store.publishProviderDerivedTokenSnapshot(from: remote.toUsageSnapshot(), for: .opencodego)
        let after = try #require(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .opencodego))
        print(
            "[opencode-history-publication] before=\(before.snapshot?.last30DaysCostUSD as Any) " +
                "after=\(after.snapshot?.last30DaysCostUSD as Any)")
        #expect(after.publicationRevision == before.publicationRevision)
        #expect(after.snapshot == before.snapshot)
        let pending = remote.toUsageSnapshot()
        store._test_providerFetchOutcomeOverride = { _ in
            ProviderFetchOutcome(result: .success(ProviderFetchResult(
                usage: pending,
                credits: nil,
                dashboard: nil,
                sourceLabel: "fixture",
                strategyID: "fixture",
                strategyKind: .apiToken)), attempts: [])
        }
        await store.refreshProvider(.opencodego, allowDisabled: true)
        #expect(store.snapshots[.opencodego]?.opencodegoUsage?.localHistoryPending == true)
        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .opencodego)?.snapshot == before.snapshot)
        remote.localHistoryPending = false
        store.publishProviderDerivedTokenSnapshot(from: remote.toUsageSnapshot(), for: .opencodego)
        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .opencodego)?.snapshot == nil)
    }
}
