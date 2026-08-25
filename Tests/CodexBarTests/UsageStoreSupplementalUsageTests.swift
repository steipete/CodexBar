import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

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

    @Test
    func `empty deferred inventory clears the legacy reset detail row`() async throws {
        let store = Self.makeStore(suite: "UsageStoreSupplementalUsageTests-clear-details")
        let gate = SupplementalUsageGate()
        let now = Date(timeIntervalSince1970: 1_787_647_576)
        let token = GrokRemainingReset(
            tokenID: "restok_sample",
            grantedAt: nil,
            expiresAt: now.addingTimeInterval(86400))
        let resetCredits = try #require(GrokRemainingResetsFetcher.snapshot(tokens: [token], now: now))
        let initial = Self.snapshot(updatedAt: now)
            .withGrokResetCredits(resetCredits)
            .replacing(details: .value(GrokRemainingResetsFetcher.detailSections(tokens: [token], now: now)))
        store._test_providerFetchOutcomeOverride = { _ in
            Self.outcome(
                snapshot: initial,
                supplementalUsageTask: Task {
                    await gate.wait()
                    return .grokResetCredits(nil)
                })
        }

        await store.refreshProvider(.grok, allowDisabled: true)
        #expect(store.snapshot(for: .grok)?.detailRow(label: "Limit Reset Credits") != nil)

        await gate.resume()
        await Self.waitForLegacyResetDetailRemoval(in: store)

        #expect(store.snapshot(for: .grok)?.grokResetCredits == nil)
        #expect(store.snapshot(for: .grok)?.detailRow(label: "Limit Reset Credits") == nil)
    }

    @Test
    func `deferred Grok credits publish to every stacked account`() async throws {
        let store = Self.makeStore(suite: "UsageStoreSupplementalUsageTests-stacked")
        store.settings.addTokenAccount(provider: .grok, label: "Personal", token: "token-personal")
        store.settings.addTokenAccount(provider: .grok, label: "Work", token: "token-work")
        let accounts = store.settings.tokenAccounts(for: .grok)
        let baseSpec = try #require(store.providerSpecs[.grok])
        let baseDescriptor = baseSpec.descriptor
        let strategy = GrokStackedAccountSupplementalStrategy()
        store.providerSpecs[.grok] = ProviderSpec(
            style: baseSpec.style,
            isEnabled: { true },
            descriptor: ProviderDescriptor(
                id: .grok,
                metadata: baseDescriptor.metadata,
                branding: baseDescriptor.branding,
                tokenCost: baseDescriptor.tokenCost,
                fetchPlan: ProviderFetchPlan(
                    sourceModes: Set(ProviderSourceMode.allCases),
                    pipeline: ProviderFetchPipeline { _ in [strategy] }),
                cli: baseDescriptor.cli),
            makeFetchContext: baseSpec.makeFetchContext)

        await store.refreshTokenAccounts(provider: .grok, accounts: accounts)
        await Self.waitForAccountResetCredits(in: store, count: accounts.count)

        let snapshots = try #require(store.accountSnapshots[.grok])
        #expect(snapshots.map(\.account.id) == accounts.map(\.id))
        #expect(snapshots.allSatisfy { $0.snapshot?.grokResetCredits != nil })
        let selected = try #require(store.settings.effectiveSelectedTokenAccount(for: .grok))
        let selectedCredits = try #require(
            snapshots.first(where: { $0.account.id == selected.id })?.snapshot?.grokResetCredits)
        #expect(store.snapshot(for: .grok)?.grokResetCredits == selectedCredits)
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

    private static func waitForLegacyResetDetailRemoval(in store: UsageStore) async {
        for _ in 0..<100 where store.snapshot(for: .grok)?.detailRow(label: "Limit Reset Credits") != nil {
            await Task.yield()
        }
    }

    private static func waitForAccountResetCredits(in store: UsageStore, count: Int) async {
        for _ in 0..<100 {
            let snapshots = store.accountSnapshots[.grok] ?? []
            if snapshots.count == count, snapshots.allSatisfy({ $0.snapshot?.grokResetCredits != nil }) {
                return
            }
            await Task.yield()
        }
    }
}

private struct GrokStackedAccountSupplementalStrategy: ProviderFetchStrategy {
    let id = "grok-stacked-supplemental-test"
    let kind: ProviderFetchKind = .oauth

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let token = context.env[GrokSettingsReader.oauthTokenEnvironmentKey] ?? "missing"
        let now = Date(timeIntervalSince1970: 1_787_647_576)
        let lifetime = token == "token-personal" ? 86400.0 : 172_800.0
        let resetCredits = GrokRateLimitResetCreditsSnapshot(
            expirations: [now.addingTimeInterval(lifetime)],
            updatedAt: now)
        return self.makeResult(
            usage: UsageSnapshot(primary: nil, secondary: nil, updatedAt: now),
            sourceLabel: self.id,
            supplementalUsageTask: Task { .grokResetCredits(resetCredits) })
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
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
