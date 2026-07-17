import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct UsageStoreCachedTokenHydrationTests {
    @Test
    func `cached codex token hydration populates startup token snapshot`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        try Self.writeCodexSessionFile(
            homeRoot: env.codexHomeRoot,
            env: env,
            day: day,
            filename: "cached.jsonl",
            tokens: 42)

        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        _ = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            historyDays: 1,
            scannerOptions: options)

        let settings = Self.makeCodexOnlySettings(historyDays: 1)
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            costUsageFetcher: CostUsageFetcher(scannerOptions: options),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])

        store.hydrateCachedTokenSnapshots(now: day)

        for _ in 0..<100 where store.tokenSnapshot(for: .codex) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.tokenSnapshot(for: .codex)?.sessionTokens == 42)
        #expect(store.tokenSnapshot(for: .codex)?.daily.map(\.date) == ["2026-04-08"])
        #expect(store.tokenError(for: .codex) == nil)
    }

    @Test
    func `cached codex token hydration skips managed codex homes`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        try Self.writeCodexSessionFile(
            homeRoot: env.codexHomeRoot,
            env: env,
            day: day,
            filename: "cached.jsonl",
            tokens: 42)

        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        _ = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            historyDays: 1,
            scannerOptions: options)

        let settings = Self.makeCodexOnlySettings(historyDays: 1)
        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: env.codexHomeRoot.path,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        settings._test_activeManagedCodexAccount = managedAccount
        settings.codexActiveSource = .managedAccount(id: managedAccount.id)
        defer { settings._test_activeManagedCodexAccount = nil }
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            costUsageFetcher: CostUsageFetcher(scannerOptions: options),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])

        store.hydrateCachedTokenSnapshots(now: day)

        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.tokenSnapshot(for: .codex) == nil)
    }

    @Test
    func `fresh cached hydration suppresses the redundant startup token refresh`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let now = Date()
        try Self.writeCodexSessionFile(
            homeRoot: env.codexHomeRoot,
            env: env,
            day: now,
            filename: "cached.jsonl",
            tokens: 42)

        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        _ = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            historyDays: 1,
            scannerOptions: options)

        let settings = Self.makeCodexOnlySettings(historyDays: 1)
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            costUsageFetcher: CostUsageFetcher(scannerOptions: options),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        var tokenRefreshCount = 0
        store._test_tokenUsageRefreshOverride = { _, _ in tokenRefreshCount += 1 }

        store.hydrateCachedTokenSnapshots(now: now)
        for _ in 0..<100 where store.tokenSnapshot(for: .codex) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        await store.refreshTokenUsageNow(for: .codex, force: false)

        #expect(store.tokenSnapshot(for: .codex)?.sessionTokens == 42)
        #expect(store.tokenLastAttemptAt(for: .codex).map { abs($0.timeIntervalSince(now)) < 0.001 } == true)
        #expect(tokenRefreshCount == 0)
    }

    @Test
    func `stale cached hydration still allows the startup token refresh`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let now = Date()
        try Self.writeCodexSessionFile(
            homeRoot: env.codexHomeRoot,
            env: env,
            day: now,
            filename: "cached.jsonl",
            tokens: 42)

        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        _ = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            historyDays: 1,
            scannerOptions: options)
        var cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        cache.lastScanUnixMs = Int64(now.addingTimeInterval(-2 * 60 * 60).timeIntervalSince1970 * 1000)
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: env.cacheRoot)

        let settings = Self.makeCodexOnlySettings(historyDays: 1)
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            costUsageFetcher: CostUsageFetcher(scannerOptions: options),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        var tokenRefreshCount = 0
        store._test_tokenUsageRefreshOverride = { _, _ in tokenRefreshCount += 1 }

        store.hydrateCachedTokenSnapshots(now: now)
        for _ in 0..<100 where store.tokenSnapshot(for: .codex) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        await store.refreshTokenUsageNow(for: .codex, force: false)

        #expect(store.tokenSnapshot(for: .codex)?.sessionTokens == 42)
        #expect(store.tokenLastAttemptAt(for: .codex) != nil)
        #expect(tokenRefreshCount == 1)
    }

    @Test
    func `confirmed empty publication wins over in flight cached codex hydration`() async {
        let settings = Self.makeCodexOnlySettings(historyDays: 1)
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let gate = CachedTokenHydrationGate()
        store._test_cachedCodexTokenSnapshotLoaderOverride = { _, _, _ in
            await gate.enter()
            return (Self.cachedTokenSnapshot(), Date())
        }

        let hydration = store.hydrateCachedTokenSnapshots()
        await gate.waitForStart()
        store.publishConfirmedEmptyTokenSnapshot(for: .codex)
        let confirmedEmptyRevision = store.tokenSnapshotPublicationRevision(for: .codex)
        await gate.release()
        await hydration?.value

        let publication = store.tokenSnapshotPublicationForCurrentProviderConfig(for: .codex)
        #expect(hydration != nil)
        #expect(publication?.snapshot == nil)
        #expect(publication?.publicationRevision == confirmedEmptyRevision)
        #expect(store.tokenSnapshot(for: .codex) == nil)
        #expect(store.tokenLastAttemptAt(for: .codex) == nil)
    }

    private static func makeCodexOnlySettings(historyDays: Int) -> SettingsStore {
        let suite = "UsageStoreCachedTokenHydrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = true
        settings.costUsageHistoryDays = historyDays
        settings.openAIWebAccessEnabled = false
        settings.codexCookieSource = .off
        settings.providerDetectionCompleted = true

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }
        return settings
    }

    private static func cachedTokenSnapshot() -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: 42,
            sessionCostUSD: 1,
            last30DaysTokens: 42,
            last30DaysCostUSD: 1,
            daily: [],
            updatedAt: Date())
    }

    private static func writeCodexSessionFile(
        homeRoot: URL,
        env: CostUsageTestEnvironment,
        day: Date,
        filename: String,
        tokens: Int) throws
    {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: day)
        let dir = homeRoot
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(String(format: "%04d", comps.year ?? 1970), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", comps.month ?? 1), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", comps.day ?? 1), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let model = "openai/gpt-5.4"
        let url = dir.appendingPathComponent(filename, isDirectory: false)
        try env.jsonl([
            [
                "type": "turn_context",
                "timestamp": env.isoString(for: day),
                "payload": ["model": model],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: day.addingTimeInterval(1)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "last_token_usage": [
                            "input_tokens": tokens,
                            "cached_input_tokens": 0,
                            "output_tokens": 0,
                        ],
                        "model": model,
                    ],
                ],
            ],
        ]).write(to: url, atomically: true, encoding: .utf8)
    }
}

private actor CachedTokenHydrationGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        self.started = true
        let waiters = self.startWaiters
        self.startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !self.released else { return }
        await withCheckedContinuation { continuation in
            self.releaseWaiters.append(continuation)
        }
    }

    func waitForStart() async {
        guard !self.started else { return }
        await withCheckedContinuation { continuation in
            self.startWaiters.append(continuation)
        }
    }

    func release() {
        self.released = true
        let waiters = self.releaseWaiters
        self.releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
