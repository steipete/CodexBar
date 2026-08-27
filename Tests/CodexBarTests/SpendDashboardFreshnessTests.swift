import Foundation
import Observation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct SpendDashboardFreshnessTests {
    @Test
    func `regular publication refreshes populated independent history exactly once`() async throws {
        let fixture = try SpendDashboardFreshnessFixture()
        defer { fixture.cleanup() }
        let store = fixture.store
        fixture.installSyntheticLoader()
        await store.refreshSpendDashboardTokenUsageNow(for: .claude, force: true)
        let initial = SpendDashboardSource.configuration(settings: fixture.settings, store: store)
        fixture.latestCost = 5
        await store.refreshTokenUsageNow(for: .claude, force: true)
        let triggered = SpendDashboardSource.configuration(settings: fixture.settings, store: store)
        #expect(triggered != initial)
        #expect(triggered.sourceRevisions.first { $0.hasPrefix("claude:") } ==
            initial.sourceRevisions.first { $0.hasPrefix("claude:") })

        let request = await fixture.request()
        #expect(fixture.requests == [365, 30, 365])
        let snapshot = try #require(request.capturedInputs.first?.snapshot)
        #expect(snapshot.daily.map(\.date) == ["2026-01-01", "2026-07-15"])
        #expect(snapshot.daily.compactMap(\.costUSD).reduce(0, +) == 15)
        #expect(store.tokenSnapshot(for: .claude)?.historyDays == 30)
        #expect(store.tokenSnapshot(for: .claude)?.daily.count == 1)

        for _ in 0..<3 {
            _ = await fixture.request()
        }
        #expect(fixture.requests == [365, 30, 365])
    }

    @Test
    func `missing independent publication never borrows short regular history`() async throws {
        let fixture = try SpendDashboardFreshnessFixture()
        defer { fixture.cleanup() }
        fixture.installSyntheticLoader()
        await fixture.store.refreshTokenUsageNow(for: .claude, force: true)
        let capture = await fixture.request(.captureOnly)
        #expect(capture.capturedInputs.isEmpty)
        #expect(capture.unavailableSourceIDs == ["claude"])
        let refreshed = await fixture.request()
        #expect(fixture.requests == [30, 365])
        #expect(refreshed.capturedInputs.first?.snapshot.daily.count == 2)
    }

    @Test
    func `ordinary refresh targets only outdated independent providers`() async throws {
        let fixture = try SpendDashboardFreshnessFixture(providers: [.claude, .vertexai])
        defer { fixture.cleanup() }
        fixture.store._test_tokenUsageSnapshotLoaderOverride = { provider, _, _, _, days in
            fixture.providerRequests.append("\(provider.rawValue):\(days)")
            return fixture.snapshot(days: days, recentCost: 2)
        }
        await fixture.store.refreshSpendDashboardTokenUsageNow(for: .claude, force: true)
        await fixture.store.refreshSpendDashboardTokenUsageNow(for: .vertexai, force: true)
        await fixture.store.refreshTokenUsageNow(for: .claude, force: true)
        _ = await fixture.request()
        #expect(fixture.providerRequests == ["claude:365", "vertexai:365", "claude:30", "claude:365"])
        await fixture.store.refreshTokenUsageNow(for: .vertexai, force: true)
        _ = await fixture.request()
        #expect(fixture.providerRequests == [
            "claude:365", "vertexai:365", "claude:30", "claude:365", "vertexai:30", "vertexai:365",
        ])
    }

    @Test
    func `shared observation coalesces newer publications after a suspended scan drains`() async throws {
        let fixture = try SpendDashboardFreshnessFixture()
        defer { fixture.cleanup() }
        fixture.installSyntheticLoader()
        await fixture.store.refreshSpendDashboardTokenUsageNow(for: .claude, force: true)
        fixture.store.startSharedSpendDashboardPublication()
        try await fixture.waitForSharedCost(2)

        let gate = SpendDashboardFreshnessGate()
        defer { gate.release.open() }
        fixture.nextDashboardGate = gate
        fixture.latestCost = 3
        await fixture.store.refreshTokenUsageNow(for: .claude, force: true)
        try await gate.arrival.wait()
        fixture.latestCost = 4
        await fixture.store.refreshTokenUsageNow(for: .claude, force: true)
        fixture.latestCost = 5
        await fixture.store.refreshTokenUsageNow(for: .claude, force: true)
        #expect(fixture.store.spendDashboardTokenIncorporatedTriggers[.claude]?.regularPublicationRevision == 0)
        gate.release.open()
        try await fixture.waitForSharedCost(5)

        #expect(fixture.requests == [365, 30, 365, 30, 30, 365])
        #expect(fixture.store.spendDashboardTokenIncorporatedTriggers[.claude]?.regularPublicationRevision == 3)
        #expect(fixture.store.spendDashboardPublication.inputs.first?.snapshot.daily.count == 2)
        #expect(fixture.store.tokenSnapshot(for: .claude)?.historyDays == 30)
        let settled = fixture.requests
        for _ in 0..<3 {
            fixture.store.sharedSpendDashboardController().update(configuration: fixture.configuration)
            _ = await fixture.request()
        }
        #expect(fixture.requests == settled)
    }

    @Test
    func `post-await configuration cannot acknowledge a revision the scan did not incorporate`() async throws {
        let fixture = try SpendDashboardFreshnessFixture()
        defer { fixture.cleanup() }
        fixture.installSyntheticLoader()
        await fixture.store.refreshSpendDashboardTokenUsageNow(for: .claude, force: true)
        await fixture.store.refreshTokenUsageNow(for: .claude, force: true)
        let gate = SpendDashboardFreshnessGate()
        defer { gate.release.open() }
        fixture.nextDashboardGate = gate
        let task = Task { await fixture.request() }
        try await gate.arrival.wait()
        fixture.latestCost = 7
        await fixture.store.refreshTokenUsageNow(for: .claude, force: true)
        gate.release.open()
        let request = await task.value
        #expect(request.configuration == fixture.configuration)
        #expect(request.independentRefreshPending)
        #expect(fixture.store.spendDashboardTokenIncorporatedTriggers[.claude]?.regularPublicationRevision == 1)

        // No observation callback is needed to rescue the swallowed revision.
        let controller = SpendDashboardController(requestBuilder: { mode in
            if mode == .refreshMissing, fixture.requestCount == 0 {
                fixture.requestCount += 1
                return request
            }
            fixture.requestCount += 1
            return await fixture.request(mode)
        }, nowProvider: { fixture.now })
        defer { controller.stop() }
        controller.update(configuration: request.configuration)
        try await SpendDashboardFreshnessSignal.waitUntil {
            !controller.isRefreshing && controller.publication.inputs.first?.snapshot.last30DaysCostUSD == 7
        }
        #expect(fixture.requestCount == 2)
        #expect(fixture.requests == [365, 30, 365, 30, 365])
    }

    @Test
    func `manual refresh reconciles before coalesced independent follow-up`() async throws {
        let fixture = try SpendDashboardFreshnessFixture()
        defer { fixture.cleanup() }
        fixture.installSyntheticLoader()
        await fixture.store.refreshSpendDashboardTokenUsageNow(for: .claude, force: true)
        fixture.store.startSharedSpendDashboardPublication()
        try await fixture.waitForSharedCost(2)
        let gate = SpendDashboardFreshnessGate()
        defer { gate.release.open() }
        fixture.nextDashboardGate = gate
        fixture.store.sharedSpendDashboardController().refresh()
        try await gate.arrival.wait()
        fixture.latestCost = 8
        await fixture.store.refreshTokenUsageNow(for: .claude, force: true)
        fixture.latestCost = 9
        await fixture.store.refreshTokenUsageNow(for: .claude, force: true)
        gate.release.open()
        try await fixture.waitForSharedCost(9)
        #expect(fixture.requests == [365, 365, 30, 30, 365])
        #expect(fixture.store.spendDashboardTokenIncorporatedTriggers[.claude]?.regularPublicationRevision == 2)
    }

    @Test
    func `replacement owner waits for cancelled scan to drain before loading its own history`() async throws {
        let fixture = try SpendDashboardFreshnessFixture()
        defer { fixture.cleanup() }
        fixture.installSyntheticLoader()
        await fixture.store.refreshSpendDashboardTokenUsageNow(for: .claude, force: true)
        fixture.store.startSharedSpendDashboardPublication()
        try await fixture.waitForSharedCost(2)
        let gate = SpendDashboardFreshnessGate()
        defer { gate.release.open() }
        fixture.nextDashboardGate = gate
        fixture.latestCost = 3
        await fixture.store.refreshTokenUsageNow(for: .claude, force: true)
        try await gate.arrival.wait()
        fixture.settings.updateProviderConfig(provider: .claude) { $0.cookieHeader = "sessionKey=fixture-next-owner" }
        let owner = fixture.configuration.sourceOwnershipFingerprints
        try await SpendDashboardFreshnessSignal.waitUntil {
            let publication = fixture.store.spendDashboardPublication
            return publication.configuration?.sourceOwnershipFingerprints == owner && !publication.isRefreshing
        }
        #expect(fixture.store.spendDashboardPublication.inputs.isEmpty)
        fixture.latestCost = 7
        gate.release.open()
        try await fixture.waitForSharedCost(7)
        #expect(fixture.store.spendDashboardPublication.configuration?.sourceOwnershipFingerprints == owner)
        #expect(fixture.requests == [365, 30, 365, 365])
    }

    @Test
    func `failed automatic attempt stays bounded and new publication or manual refresh recovers`() async throws {
        let fixture = try SpendDashboardFreshnessFixture()
        defer { fixture.cleanup() }
        fixture.installSyntheticLoader()
        await fixture.store.refreshSpendDashboardTokenUsageNow(for: .claude, force: true)
        fixture.store.startSharedSpendDashboardPublication()
        try await fixture.waitForSharedCost(2)
        fixture.failDashboard = true
        await fixture.store.refreshTokenUsageNow(for: .claude, force: true)
        try await SpendDashboardFreshnessSignal.waitUntil {
            !fixture.store.spendDashboardPublication.isRefreshing &&
                fixture.store.spendDashboardPublication.sources.first?.state == .staleLastKnown
        }
        #expect(fixture.store.spendDashboardTokenIncorporatedTriggers[.claude]?.regularPublicationRevision == 0)
        #expect(fixture.store.spendDashboardTokenFailedTriggers[.claude]?.regularPublicationRevision == 1)
        #expect(fixture.store.spendDashboardPublication.inputs.first?.snapshot.last30DaysCostUSD == 2)
        for _ in 0..<3 {
            _ = await fixture.request()
        }
        #expect(fixture.requests == [365, 30, 365])

        fixture.failDashboard = false
        fixture.latestCost = 6
        await fixture.store.refreshTokenUsageNow(for: .claude, force: true)
        try await fixture.waitForSharedCost(6)
        fixture.failDashboard = true
        fixture.store.sharedSpendDashboardController().refresh()
        try await SpendDashboardFreshnessSignal.waitUntil {
            !fixture.store.spendDashboardPublication.isRefreshing &&
                fixture.store.spendDashboardPublication.sources.first?.state == .staleLastKnown
        }
        fixture.failDashboard = false
        fixture.latestCost = 9
        fixture.store.sharedSpendDashboardController().refresh()
        try await fixture.waitForSharedCost(9)
        #expect(fixture.store.spendDashboardTokenFailedTriggers[.claude] == nil)
        #expect(fixture.requests == [365, 30, 365, 30, 365, 365, 365])
    }

    @Test
    func `confirmed empty scan acknowledges its trigger without a retry loop`() async throws {
        let fixture = try SpendDashboardFreshnessFixture()
        defer { fixture.cleanup() }
        fixture.installSyntheticLoader()
        await fixture.store.refreshSpendDashboardTokenUsageNow(for: .claude, force: true)
        fixture.emptyDashboard = true
        await fixture.store.refreshTokenUsageNow(for: .claude, force: true)
        let request = await fixture.request()
        #expect(request.confirmedEmptySourceIDs == ["claude"])
        #expect(request.capturedInputs.isEmpty)
        #expect(!request.independentRefreshPending)
        #expect(fixture.store.spendDashboardTokenIncorporatedTriggers[.claude]?.regularPublicationRevision == 1)
        for _ in 0..<3 {
            _ = await fixture.request()
        }
        #expect(fixture.requests == [365, 30, 365])
    }

    @Test(arguments: ["cancel", "disable", "account"])
    func `invalidated suspended completion cannot acknowledge or publish`(_ change: String) async throws {
        let fixture = try SpendDashboardFreshnessFixture()
        defer { fixture.cleanup() }
        fixture.installSyntheticLoader()
        await fixture.store.refreshTokenUsageNow(for: .claude, force: true)
        let gate = SpendDashboardFreshnessGate()
        defer { gate.release.open() }
        fixture.nextDashboardGate = gate
        let task = Task { await fixture.request() }
        try await gate.arrival.wait()
        switch change {
        case "cancel": task.cancel()
        case "disable":
            fixture.settings.setProviderEnabled(
                provider: .claude, metadata: fixture.store.metadata(for: .claude), enabled: false)
        default:
            fixture.settings
                .updateProviderConfig(provider: .claude) { $0.cookieHeader = "sessionKey=fixture-other-owner" }
        }
        gate.release.open()
        _ = await task.value
        #expect(fixture.store.spendDashboardTokenSnapshotPublicationForCurrentConfig(for: .claude) == nil)
        #expect(fixture.store.spendDashboardTokenIncorporatedTriggers[.claude] == nil)
        #expect(fixture.store.spendDashboardTokenFailedTriggers[.claude] == nil)
        if change == "disable" {
            fixture.settings.setProviderEnabled(
                provider: .claude, metadata: fixture.store.metadata(for: .claude), enabled: true)
        }
        let recovered = await fixture.request()
        #expect(recovered.capturedInputs.first?.snapshot.daily.count == 2)
        #expect(fixture.requests == [30, 365, 365])
    }
}

@MainActor
final class SpendDashboardFreshnessFixture {
    let env: CostUsageTestEnvironment
    let settings: SettingsStore
    let store: UsageStore
    let now = Date(timeIntervalSince1970: 1_784_179_200)
    var latestCost = 2.0
    var requests: [Int] = []
    var providerRequests: [String] = []
    var requestCount = 0
    var nextDashboardGate: SpendDashboardFreshnessGate?
    var failDashboard = false
    var emptyDashboard = false

    var configuration: SpendDashboardConfiguration {
        SpendDashboardSource.configuration(settings: self.settings, store: self.store)
    }

    init(providers: Set<UsageProvider> = [.claude]) throws {
        self.env = try CostUsageTestEnvironment()
        self.settings = testSettingsStore(
            suiteName: "SpendDashboardFreshnessTests",
            config: CodexBarConfig(providers: UsageProvider.allCases.map {
                ProviderConfig(id: $0.instanceID, enabled: providers.contains($0))
            }),
            prepareDefaults: {
                $0.set(AppGroupSupport.migrationVersion, forKey: AppGroupSupport.migrationVersionKey)
                $0.set(true, forKey: "codexbar.legacySecretsMigrationCompleted")
                $0.set(true, forKey: "debugDisableKeychainAccess")
                $0.set(true, forKey: "providerDetectionCompleted")
            })
        self.settings.costUsageEnabled = true
        self.settings.costUsageHistoryDays = 30
        self.settings.costUsageBucketTimeZoneIdentifier = "UTC"
        self.settings.openCodexUsageLogsEnabled = false
        let environment = ["HOME": self.env.root.path, "CODEX_HOME": self.env.codexHomeRoot.path]
        self.settings._test_codexReconciliationEnvironment = environment
        self.store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(homeDirectory: self.env.root.path, cacheTTL: 0),
            settings: self.settings,
            startupBehavior: .testing,
            environmentBase: environment)
        self.store._test_providerRefreshOverride = { _ in Issue.record("Unexpected provider transport") }
        self.store._test_widgetSnapshotSaveOverride = { _ in }
    }

    func cleanup() {
        self.store.stopSharedSpendDashboardPublication()
        self.store._test_tokenUsageSnapshotLoaderOverride = nil
        self.env.cleanup()
    }

    func installSyntheticLoader() {
        self.store._test_tokenUsageSnapshotLoaderOverride = { [self] provider, _, _, _, days in
            #expect(provider == .claude)
            self.requests.append(days)
            let snapshot = self.snapshot(days: days, recentCost: self.latestCost)
            if days == 365 {
                if let gate = self.nextDashboardGate {
                    self.nextDashboardGate = nil
                    gate.arrival.open()
                    try await gate.release.wait()
                }
                if self.failDashboard { throw SpendDashboardFreshnessError.syntheticFailure }
                if self.emptyDashboard {
                    return CostUsageTokenSnapshot(
                        sessionTokens: nil,
                        sessionCostUSD: nil,
                        last30DaysTokens: nil,
                        last30DaysCostUSD: nil,
                        historyDays: days,
                        daily: [],
                        updatedAt: self.now)
                }
            }
            return snapshot
        }
    }

    func waitForSharedCost(_ cost: Double) async throws {
        try await SpendDashboardFreshnessSignal.waitUntil {
            let publication = self.store.spendDashboardPublication
            let actual = publication.inputs.first?.snapshot.last30DaysCostUSD ?? -1
            return !publication.isRefreshing && abs(actual - cost) < 0.000000001 &&
                publication.sources.first?.state == .available
        }
    }

    func request(_ mode: SpendDashboardRequestBuildMode = .refreshMissing) async -> SpendDashboardLoadRequest {
        await SpendDashboardSource.makeRequest(settings: self.settings, store: self.store, mode: mode, now: self.now)
    }

    func snapshot(days: Int, recentCost: Double) -> CostUsageTokenSnapshot {
        let rows: [(String, Double)] = days == 365
            ? [("2026-01-01", 10), ("2026-07-15", recentCost)] : [("2026-07-15", recentCost)]
        return CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 100,
            last30DaysCostUSD: recentCost,
            historyDays: days,
            daily: rows.map { day, cost in
                CostUsageDailyReport.Entry(
                    date: day,
                    inputTokens: 100,
                    outputTokens: 0,
                    totalTokens: 100,
                    costUSD: cost,
                    modelsUsed: nil,
                    modelBreakdowns: nil)
            },
            updatedAt: self.now)
    }
}

enum SpendDashboardFreshnessError: Error {
    case timedOut
    case syntheticFailure
}

@MainActor
final class SpendDashboardFreshnessGate {
    let arrival = SpendDashboardFreshnessSignal()
    let release = SpendDashboardFreshnessSignal()
}

@MainActor
final class SpendDashboardFreshnessSignal {
    private var opened = false
    private var waiter: CheckedContinuation<Void, any Error>?
    private var timeout: Task<Void, Never>?

    func open() {
        self.opened = true
        self.timeout?.cancel()
        self.timeout = nil
        self.waiter?.resume()
        self.waiter = nil
    }

    func wait() async throws {
        if self.opened { return }
        try await withCheckedThrowingContinuation { continuation in
            precondition(self.waiter == nil)
            self.waiter = continuation
            self.timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                self?.waiter?.resume(throwing: SpendDashboardFreshnessError.timedOut)
                self?.waiter = nil
                self?.timeout = nil
            }
        }
    }

    static func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        let signal = SpendDashboardFreshnessSignal()
        signal.observe(condition)
        defer { signal.open() }
        try await signal.wait()
    }

    private func observe(_ condition: @escaping @MainActor () -> Bool) {
        guard !self.opened else { return }
        if withObservationTracking(condition, onChange: {
            Task { @MainActor in self.observe(condition) }
        }) { self.open() }
    }
}
