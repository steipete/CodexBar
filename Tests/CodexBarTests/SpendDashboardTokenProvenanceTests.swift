import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct SpendDashboardTokenProvenanceTests {
    @Test
    func `direct token scan rejects stale config completion`() async {
        let (settings, store) = Self.makeStore(provider: .bedrock)
        settings.updateProviderConfig(provider: .bedrock) { $0.region = "us-east-1" }
        let gate = SpendDashboardProvenanceGate()
        store._test_tokenUsageSnapshotLoaderOverride = { _, _, _, _, _ in
            let call = await gate.enter()
            return Self.tokenSnapshot(cost: call == 1 ? 1 : 2)
        }

        let refresh = Task { @MainActor in
            await store.refreshTokenUsageNow(for: .bedrock, force: true)
        }
        await gate.waitForCalls(1)
        settings.updateProviderConfig(provider: .bedrock) { $0.region = "us-west-2" }
        await gate.releaseFirst()
        await refresh.value
        await gate.waitForCalls(2)
        await Self.waitUntil {
            store.tokenSnapshotForCurrentProviderConfig(for: .bedrock)?.snapshot.last30DaysCostUSD == 2
        }

        #expect(store.tokenSnapshotForCurrentProviderConfig(for: .bedrock)?.snapshot.last30DaysCostUSD == 2)
        #expect(store.tokenSnapshotPublicationRevision(for: .bedrock) == 1)
    }

    @Test
    func `direct token scan rejects completion across disable and reenable epoch`() async {
        let (settings, store) = Self.makeStore(provider: .bedrock)
        let gate = SpendDashboardProvenanceGate()
        store._test_tokenUsageSnapshotLoaderOverride = { _, _, _, _, _ in
            let call = await gate.enter()
            return Self.tokenSnapshot(cost: call == 1 ? 1 : 2)
        }

        let refresh = Task { @MainActor in
            await store.refreshTokenUsageNow(for: .bedrock, force: true)
        }
        await gate.waitForCalls(1)
        settings.costUsageEnabled = false
        settings.costUsageEnabled = true
        await gate.releaseFirst()
        await refresh.value
        await gate.waitForCalls(2)
        await Self.waitUntil {
            store.tokenSnapshotForCurrentProviderConfig(for: .bedrock)?.snapshot.last30DaysCostUSD == 2
        }

        #expect(store.tokenSnapshotForCurrentProviderConfig(for: .bedrock)?.snapshot.last30DaysCostUSD == 2)
        #expect(store.tokenSnapshotPublicationRevision(for: .bedrock) == 1)
    }

    @Test
    func `direct token scan refreshes changed provider config within ttl`() async {
        let (settings, store) = Self.makeStore(provider: .bedrock)
        settings.updateProviderConfig(provider: .bedrock) { $0.region = "us-east-1" }
        var loadCount = 0
        store._test_tokenUsageSnapshotLoaderOverride = { _, _, _, _, _ in
            loadCount += 1
            return Self.tokenSnapshot(cost: Double(loadCount))
        }

        await store.refreshTokenUsageNow(for: .bedrock, force: true)
        #expect(store.tokenSnapshotForCurrentProviderConfig(for: .bedrock)?.snapshot.last30DaysCostUSD == 1)

        settings.updateProviderConfig(provider: .bedrock) { $0.region = "us-west-2" }
        await store.refreshTokenUsageNow(for: .bedrock, force: false)

        #expect(loadCount == 2)
        #expect(store.tokenSnapshotForCurrentProviderConfig(for: .bedrock)?.snapshot.last30DaysCostUSD == 2)
        #expect(store.tokenSnapshotPublicationRevision(for: .bedrock) == 2)
    }

    @Test
    func `provider derived snapshot rejects completion from old history scope`() async {
        let (settings, store) = Self.makeStore(provider: .mistral)
        let gate = SpendDashboardProvenanceGate()
        store._test_providerFetchOutcomeOverride = { _ in
            _ = await gate.enter()
            return Self.mistralOutcome(cost: 4)
        }

        let refresh = Task { @MainActor in
            await store.refreshProvider(.mistral)
        }
        await gate.waitForCalls(1)
        settings.costUsageHistoryDays = 7
        await gate.releaseFirst()
        await refresh.value

        #expect(store.tokenSnapshotForCurrentProviderConfig(for: .mistral) == nil)
        #expect(store.tokenSnapshotPublicationRevision(for: .mistral) == 0)
    }

    @Test
    func `cached token account activation does not prove a forced refresh`() async throws {
        let (settings, store) = Self.makeStore(provider: .mistral)
        settings.addTokenAccount(provider: .mistral, label: "Fixture", token: "fixture")
        let account = try #require(settings.effectiveSelectedTokenAccount(for: .mistral))
        let usage = Self.mistralUsage(cost: 3)
        store.accountSnapshots[.mistral] = [TokenAccountUsageSnapshot(
            account: account,
            snapshot: usage,
            error: nil,
            sourceLabel: "fixture-cache",
            cacheKey: store.tokenAccountSnapshotCacheKey(provider: .mistral, account: account))]
        store.tokenErrors[.mistral] = "stale account cost error"
        _ = store.tokenFailureGates[.mistral]?.shouldSurfaceError(onFailureWithPriorData: false)
        store.activateCachedTokenAccountSnapshot(provider: .mistral, accountID: account.id)
        let baselineRevision = store.tokenSnapshotPublicationRevision(for: .mistral)
        #expect(store.tokenSnapshot(for: .mistral)?.last30DaysCostUSD == 3)
        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .mistral)?.snapshot?.last30DaysCostUSD == 3)
        #expect(store.tokenError(for: .mistral) == nil)
        #expect(store.tokenFailureGates[.mistral]?.streak == 0)

        store.activateCachedTokenAccountSnapshot(provider: .mistral, accountID: account.id)
        #expect(store.tokenSnapshotPublicationRevision(for: .mistral) == baselineRevision)
        store._test_providerRefreshOverride = { _ in }
        let controller = SpendDashboardController(requestBuilder: { mode in
            await SpendDashboardSource.makeRequest(settings: settings, store: store, mode: mode)
        })
        controller.update(configuration: SpendDashboardSource.configuration(settings: settings, store: store))
        await Self.waitUntil { !controller.isRefreshing }
        #expect(controller.model.groups.first?.totalCost == 3)

        controller.refresh()
        await Self.waitUntil { !controller.isRefreshing }

        #expect(controller.model.groups.first?.totalCost == 3)
        #expect(controller.failedSourceCount == 1)
        #expect(store.tokenSnapshotPublicationRevision(for: .mistral) == baselineRevision)
    }

    @Test
    func `forced successful empty publication removes prior spend without warning`() async {
        let (settings, store) = Self.makeStore(provider: .bedrock)
        var loadCount = 0
        store._test_tokenUsageSnapshotLoaderOverride = { _, _, _, _, _ in
            loadCount += 1
            return loadCount == 1 ? Self.tokenSnapshot(cost: 4) : Self.emptyTokenSnapshot()
        }
        await store.refreshTokenUsageNow(for: .bedrock, force: true)
        let controller = SpendDashboardController(requestBuilder: { mode in
            await SpendDashboardSource.makeRequest(settings: settings, store: store, mode: mode)
        })
        controller.update(configuration: SpendDashboardSource.configuration(settings: settings, store: store))
        await Self.waitUntil { !controller.isRefreshing }
        #expect(controller.model.groups.first?.totalCost == 4)

        controller.refresh()
        await Self.waitUntil { !controller.isRefreshing }

        #expect(loadCount == 2)
        #expect(controller.model.groups.isEmpty)
        #expect(controller.failedSourceCount == 0)
        #expect(store.tokenSnapshot(for: .bedrock) == nil)
        let publication = store.tokenSnapshotPublicationForCurrentProviderConfig(for: .bedrock)
        #expect(publication?.snapshot == nil)
        #expect(publication?.publicationRevision == 2)
    }

    @Test
    func `first open accepts current empty publication without redundant refresh`() async {
        let (settings, store) = Self.makeStore(provider: .bedrock)
        var loadCount = 0
        store._test_tokenUsageSnapshotLoaderOverride = { _, _, _, _, _ in
            loadCount += 1
            return Self.emptyTokenSnapshot()
        }
        await store.refreshTokenUsageNow(for: .bedrock, force: true)
        let publicationRevision = store.tokenSnapshotPublicationRevision(for: .bedrock)
        let controller = SpendDashboardController(requestBuilder: { mode in
            await SpendDashboardSource.makeRequest(settings: settings, store: store, mode: mode)
        })

        controller.update(configuration: SpendDashboardSource.configuration(settings: settings, store: store))
        await Self.waitUntil { !controller.isRefreshing }

        #expect(loadCount == 1)
        #expect(controller.model.groups.isEmpty)
        #expect(controller.failedSourceCount == 0)
        #expect(store.tokenSnapshotPublicationRevision(for: .bedrock) == publicationRevision)
    }

    @Test
    func `provider success without cost projection confirms empty publication`() async {
        let (_, store) = Self.makeStore(provider: .mistral)
        let outcome = Self.mistralOutcomeWithoutCostProjection()

        await store.applySelectedOutcome(
            outcome,
            provider: .mistral,
            account: nil,
            fallbackSnapshot: nil)

        let publication = store.tokenSnapshotPublicationForCurrentProviderConfig(for: .mistral)
        #expect(publication?.snapshot == nil)
        #expect(publication?.publicationRevision == 1)
        #expect(store.tokenSnapshot(for: .mistral) == nil)
    }

    @Test
    func `legacy token refresh preserves current confirmed empty provider publication`() async {
        let (_, store) = Self.makeStore(provider: .mistral)
        await store.applySelectedOutcome(
            Self.mistralOutcomeWithoutCostProjection(),
            provider: .mistral,
            account: nil,
            fallbackSnapshot: nil)
        let publicationRevision = store.tokenSnapshotPublicationRevision(for: .mistral)

        await store.refreshTokenUsage(.mistral, force: true)

        let publication = store.tokenSnapshotPublicationForCurrentProviderConfig(for: .mistral)
        #expect(publication?.snapshot == nil)
        #expect(publication?.publicationRevision == publicationRevision)
        #expect(store.tokenError(for: .mistral) == nil)
    }

    @Test
    func `multi account provider success publishes current token provenance`() async throws {
        let (settings, store) = Self.makeStore(provider: .mistral)
        settings.addTokenAccount(provider: .mistral, label: "Fixture", token: "fixture")
        let account = try #require(settings.effectiveSelectedTokenAccount(for: .mistral))
        store.tokenErrors[.mistral] = "stale account cost error"
        _ = store.tokenFailureGates[.mistral]?.shouldSurfaceError(onFailureWithPriorData: false)

        await store.applySelectedOutcome(
            Self.mistralOutcome(cost: 7),
            provider: .mistral,
            account: account,
            fallbackSnapshot: nil)

        #expect(store.tokenSnapshotForCurrentProviderConfig(for: .mistral)?.snapshot.last30DaysCostUSD == 7)
        #expect(store.tokenSnapshotPublicationRevision(for: .mistral) == 1)
        #expect(store.tokenError(for: .mistral) == nil)
        #expect(store.tokenFailureGates[.mistral]?.streak == 0)
    }

    @Test
    func `legacy token refresh cannot stamp raw provider snapshot without provenance`() async {
        let (_, store) = Self.makeStore(provider: .mistral)
        store._setSnapshotForTesting(Self.mistralUsage(cost: 8), provider: .mistral)

        await store.refreshTokenUsage(.mistral, force: true)

        #expect(store.snapshot(for: .mistral) != nil)
        #expect(store.tokenSnapshotForCurrentProviderConfig(for: .mistral) == nil)
        #expect(store.tokenSnapshotPublicationRevision(for: .mistral) == 0)
    }

    @Test
    func `widget does not project raw provider cost without current provenance`() async throws {
        let (_, store) = Self.makeStore(provider: .mistral)
        store._setSnapshotForTesting(Self.mistralUsage(cost: 8), provider: .mistral)
        var savedSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { savedSnapshots.append($0) }

        store.persistWidgetSnapshot(reason: "provenance-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(savedSnapshots.last?.entries.first { $0.provider == .mistral })
        #expect(entry.tokenUsage == nil)
        #expect(entry.dailyUsage.isEmpty)
    }

    @Test
    func `token publication counter remains monotonic across clear and identical republish`() {
        let (_, store) = Self.makeStore(provider: .claude)
        let snapshot = Self.tokenSnapshot(cost: 9)
        store._setTokenSnapshotForTesting(snapshot, provider: .claude)
        let firstRevision = store.tokenSnapshotPublicationRevision(for: .claude)

        store._setTokenSnapshotForTesting(nil, provider: .claude)
        store._setTokenSnapshotForTesting(snapshot, provider: .claude)

        #expect(store.tokenSnapshotPublicationRevision(for: .claude) > firstRevision)
        #expect(store.tokenSnapshotForCurrentProviderConfig(for: .claude)?.snapshot == snapshot)
    }

    private static func makeStore(provider: UsageProvider) -> (SettingsStore, UsageStore) {
        let settings = testSettingsStore(suiteName: "SpendDashboardTokenProvenanceTests-\(provider.rawValue)")
        settings.costUsageEnabled = true
        for candidate in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[candidate] else { continue }
            settings.setProviderEnabled(provider: candidate, metadata: metadata, enabled: candidate == provider)
        }
        if provider == .bedrock {
            settings.updateProviderConfig(provider: .bedrock) { config in
                config.awsAuthMode = BedrockAuthMode.profile.rawValue
                config.awsProfile = "fixture"
            }
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        return (settings, store)
    }

    private static func tokenSnapshot(cost: Double) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: 10,
            sessionCostUSD: cost,
            last30DaysTokens: 10,
            last30DaysCostUSD: cost,
            daily: [CostUsageDailyReport.Entry(
                date: "2026-07-16",
                inputTokens: 4,
                outputTokens: 6,
                totalTokens: 10,
                costUSD: cost,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            updatedAt: Date(timeIntervalSince1970: 1_784_203_200))
    }

    private static func emptyTokenSnapshot() -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 0,
            last30DaysCostUSD: 0,
            daily: [],
            updatedAt: Date(timeIntervalSince1970: 1_784_179_200))
    }

    private static func mistralUsage(cost: Double) -> UsageSnapshot {
        MistralUsageSnapshot(
            totalCost: cost,
            currency: "USD",
            currencySymbol: "$",
            totalInputTokens: 4,
            totalOutputTokens: 6,
            totalCachedTokens: 0,
            modelCount: 1,
            daily: [MistralDailyUsageBucket(
                day: "2026-07-16",
                cost: cost,
                inputTokens: 4,
                cachedTokens: 0,
                outputTokens: 6,
                models: [])],
            startDate: nil,
            endDate: nil,
            updatedAt: Date(timeIntervalSince1970: 1_784_179_200))
            .toUsageSnapshot()
    }

    private static func mistralOutcome(cost: Double) -> ProviderFetchOutcome {
        ProviderFetchOutcome(
            result: .success(ProviderFetchResult(
                usage: self.mistralUsage(cost: cost),
                credits: nil,
                dashboard: nil,
                sourceLabel: "fixture",
                strategyID: "fixture",
                strategyKind: .apiToken)),
            attempts: [])
    }

    private static func mistralOutcomeWithoutCostProjection() -> ProviderFetchOutcome {
        ProviderFetchOutcome(
            result: .success(ProviderFetchResult(
                usage: UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date()),
                credits: nil,
                dashboard: nil,
                sourceLabel: "fixture",
                strategyID: "fixture",
                strategyKind: .apiToken)),
            attempts: [])
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1000 {
            if condition() {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for provenance state")
    }
}

private actor SpendDashboardProvenanceGate {
    private var callCount = 0
    private var firstReleased = false
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var callWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func enter() async -> Int {
        self.callCount += 1
        let call = self.callCount
        let ready = self.callWaiters.filter { self.callCount >= $0.count }
        self.callWaiters.removeAll { self.callCount >= $0.count }
        ready.forEach { $0.continuation.resume() }
        if call == 1, !self.firstReleased {
            await withCheckedContinuation { continuation in
                self.releaseContinuations.append(continuation)
            }
        }
        return call
    }

    func waitForCalls(_ count: Int) async {
        if self.callCount >= count {
            return
        }
        await withCheckedContinuation { continuation in
            self.callWaiters.append((count, continuation))
        }
    }

    func releaseFirst() {
        self.firstReleased = true
        let continuations = self.releaseContinuations
        self.releaseContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}
