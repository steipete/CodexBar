import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct UsageStoreSupplementalUsageTests {
    @Test
    func `deferred Grok reset credits publish after primary usage`() async {
        let store = Self.makeStore(suite: "UsageStoreSupplementalUsageTests-publish")
        let gate = SupplementalUsageGate()
        let now = Date(timeIntervalSince1970: 1_787_647_576)
        let resetCredits = GrokRateLimitResetCreditsSnapshot(
            expirations: [now.addingTimeInterval(86400)],
            updatedAt: now)
        store._test_providerFetchOutcomeOverride = { _ in
            Self.outcome(
                snapshot: Self.snapshot(updatedAt: now),
                supplementalUsageTask: Task {
                    await gate.wait()
                    return .grokResetCredits(resetCredits)
                })
        }

        await store.refreshProvider(.grok, allowDisabled: true)

        #expect(store.snapshot(for: .grok)?.primary?.usedPercent == 29)
        #expect(store.snapshot(for: .grok)?.grokResetCredits == nil)

        await gate.resume()
        await Self.waitForResetCredits(in: store)

        #expect(store.snapshot(for: .grok)?.grokResetCredits == resetCredits)
    }

    @Test
    func `new Grok refresh rejects an older deferred reset snapshot`() async {
        let store = Self.makeStore(suite: "UsageStoreSupplementalUsageTests-stale")
        let gate = SupplementalUsageGate()
        let firstUpdatedAt = Date(timeIntervalSince1970: 1_787_647_576)
        let secondUpdatedAt = firstUpdatedAt.addingTimeInterval(60)
        let staleCredits = GrokRateLimitResetCreditsSnapshot(
            expirations: [firstUpdatedAt.addingTimeInterval(86400)],
            updatedAt: firstUpdatedAt)
        store._test_providerFetchOutcomeOverride = { _ in
            Self.outcome(
                snapshot: Self.snapshot(updatedAt: firstUpdatedAt),
                supplementalUsageTask: Task {
                    await gate.wait()
                    return .grokResetCredits(staleCredits)
                })
        }
        await store.refreshProvider(.grok, allowDisabled: true)

        store._test_providerFetchOutcomeOverride = { _ in
            Self.outcome(snapshot: Self.snapshot(updatedAt: secondUpdatedAt))
        }
        await store.refreshProvider(.grok, allowDisabled: true)
        await gate.resume()
        await Self.waitForResetCredits(in: store)

        #expect(store.snapshot(for: .grok)?.updatedAt == secondUpdatedAt)
        #expect(store.snapshot(for: .grok)?.grokResetCredits == nil)
    }

    private static func makeStore(suite: String) -> UsageStore {
        let settings = testSettingsStore(suiteName: suite)
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        return UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
    }

    private static func snapshot(updatedAt: Date) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 29,
                windowMinutes: 7 * 24 * 60,
                resetsAt: updatedAt.addingTimeInterval(5 * 86400),
                resetDescription: nil),
            secondary: nil,
            updatedAt: updatedAt)
    }

    private static func outcome(
        snapshot: UsageSnapshot,
        supplementalUsageTask: Task<ProviderSupplementalUsageUpdate, Never>? = nil) -> ProviderFetchOutcome
    {
        ProviderFetchOutcome(
            result: .success(ProviderFetchResult(
                usage: snapshot,
                credits: nil,
                dashboard: nil,
                sourceLabel: "fixture",
                strategyID: "grok.fixture",
                strategyKind: .cli,
                supplementalUsageTask: supplementalUsageTask)),
            attempts: [])
    }

    private static func waitForResetCredits(in store: UsageStore) async {
        for _ in 0..<100 where store.snapshot(for: .grok)?.grokResetCredits == nil {
            await Task.yield()
        }
    }
}

private actor SupplementalUsageGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !self.isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        self.isOpen = true
        self.continuation?.resume()
        self.continuation = nil
    }
}
