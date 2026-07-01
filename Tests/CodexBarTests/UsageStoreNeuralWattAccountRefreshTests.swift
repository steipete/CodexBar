import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

private actor NeuralWattAccountRefreshRecorder {
    private(set) var dates: [Date] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record() {
        self.dates.append(Date())
        let ready = self.waiters.filter { self.dates.count >= $0.count }
        self.waiters.removeAll { self.dates.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }

    func waitForCount(_ count: Int) async {
        if self.dates.count >= count { return }
        await withCheckedContinuation { continuation in
            self.waiters.append((count, continuation))
        }
    }
}

private struct NeuralWattAccountRefreshStrategy: ProviderFetchStrategy {
    let recorder: NeuralWattAccountRefreshRecorder

    let id = "neuralwatt-account-refresh-test"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        await self.recorder.record()
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 25,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        return self.makeResult(usage: snapshot, sourceLabel: self.id)
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

@MainActor
@Suite(.serialized)
struct UsageStoreNeuralWattAccountRefreshTests {
    @Test
    func `multi-account refresh respects Neuralwatt quota rate limit`() async throws {
        let recorder = NeuralWattAccountRefreshRecorder()
        let store = try Self.makeStore(recorder: recorder)
        let accounts = [
            ProviderTokenAccount(id: UUID(), label: "First", token: "sk-first", addedAt: 0, lastUsed: nil),
            ProviderTokenAccount(id: UUID(), label: "Second", token: "sk-second", addedAt: 0, lastUsed: nil),
        ]

        await store.refreshTokenAccounts(provider: .neuralwatt, accounts: accounts)

        let dates = await recorder.dates
        #expect(dates.count == 2)
        #expect(dates[1].timeIntervalSince(dates[0]) >= 0.95)
    }

    @Test
    func `cancelled delayed refresh preserves every prior account snapshot`() async throws {
        let recorder = NeuralWattAccountRefreshRecorder()
        let store = try Self.makeStore(recorder: recorder)
        let accounts = (0..<3).map { index in
            ProviderTokenAccount(
                id: UUID(),
                label: "Account \(index)",
                token: "sk-\(index)",
                addedAt: 0,
                lastUsed: nil)
        }
        store.accountSnapshots[.neuralwatt] = accounts.map { account in
            TokenAccountUsageSnapshot(
                account: account,
                snapshot: Self.snapshot(),
                error: nil,
                sourceLabel: "prior")
        }

        let task = Task { @MainActor in
            await store.refreshTokenAccounts(provider: .neuralwatt, accounts: accounts)
        }
        await recorder.waitForCount(1)
        task.cancel()
        await task.value

        #expect(store.accountSnapshots[.neuralwatt]?.map(\.account.id) == accounts.map(\.id))
        #expect(store.accountSnapshots[.neuralwatt]?.allSatisfy { $0.snapshot != nil } == true)
    }

    private static func makeStore(recorder: NeuralWattAccountRefreshRecorder) throws -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "UsageStoreNeuralWattAccountRefreshTests-\(UUID().uuidString)",
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.providerDetectionCompleted = true
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let baseSpec = try #require(store.providerSpecs[.neuralwatt])
        let baseDescriptor = baseSpec.descriptor
        let strategy = NeuralWattAccountRefreshStrategy(recorder: recorder)
        store.providerSpecs[.neuralwatt] = ProviderSpec(
            style: baseSpec.style,
            isEnabled: baseSpec.isEnabled,
            descriptor: ProviderDescriptor(
                id: .neuralwatt,
                metadata: baseDescriptor.metadata,
                branding: baseDescriptor.branding,
                tokenCost: baseDescriptor.tokenCost,
                fetchPlan: ProviderFetchPlan(
                    sourceModes: [.auto, .api],
                    pipeline: ProviderFetchPipeline { _ in [strategy] }),
                cli: baseDescriptor.cli),
            makeFetchContext: baseSpec.makeFetchContext)
        return store
    }

    private static func snapshot() -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 25,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
    }
}
