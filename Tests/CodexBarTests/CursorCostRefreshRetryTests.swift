import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct CursorCostRefreshRetryTests {
    @Test
    func `forbidden cost requests wait for the normal cadence without a published snapshot`() async throws {
        let forbidden = try await Self.forbiddenCostError()
        try await Self.withFixture(fingerprint: "cookie-a", frequency: .fiveMinutes) { fixture in
            fixture.results = [.failure(forbidden), .failure(forbidden)]
            let quota = UsageSnapshot(
                primary: RateWindow(usedPercent: 25, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date())
            fixture.store._setSnapshotForTesting(quota, provider: .cursor)

            await fixture.store.refreshTokenUsageNow(for: .cursor, force: false)
            await fixture.settle()
            await fixture.store.refreshTokenUsageNow(for: .cursor, force: false)
            await fixture.settle()

            fixture.expectIdle(loadCount: 1)
            #expect(fixture.store.tokenSnapshot(for: .cursor) == nil)
            #expect(fixture.store.tokenError(for: .cursor) == "Cursor API error: HTTP 403")
            #expect(fixture.store.snapshot(for: .cursor)?.primary == quota.primary)
            #expect(fixture.store.snapshot(for: .cursor)?.updatedAt == quota.updatedAt)
        }
    }

    @Test
    func `surfacing a forbidden failure does not discard its cooldown with the snapshot`() async throws {
        try await Self.withFixture(fingerprint: "cookie-a", frequency: .fiveMinutes) { fixture in
            fixture.results = Array(repeating: .failure(CursorStatusProbeError.costRequestForbidden), count: 3)
            fixture.store.installCachedTokenSnapshot(Self.snapshot("cookie-a"), for: .cursor)

            await fixture.store.refreshTokenUsageNow(for: .cursor, force: true)
            await fixture.store.refreshTokenUsageNow(for: .cursor, force: true)
            #expect(fixture.store.tokenSnapshot(for: .cursor) == nil)
            await fixture.store.refreshTokenUsageNow(for: .cursor, force: false)
            await fixture.settle()

            fixture.expectIdle(loadCount: 2)
            #expect(fixture.forced == [true, true])
        }
    }

    @Test
    func `expiry permits another attempt and manual refresh can recover immediately`() async throws {
        try await Self.withFixture(fingerprint: "cookie-a", frequency: .fiveMinutes) { fixture in
            fixture.results = [
                .failure(CursorStatusProbeError.costRequestForbidden),
                .failure(CursorStatusProbeError.costRequestForbidden),
                .success(Self.snapshot("cookie-a")),
            ]
            let store = fixture.store
            await store.refreshTokenUsageNow(for: .cursor, force: false)
            let failure = try #require(store.tokenFetchFailureCooldowns[.cursor])
            let ttl = try #require(store.tokenFetchTTL)
            #expect(store.tokenRefreshFailureIsCoolingDown(
                provider: .cursor, now: failure.attemptedAt.addingTimeInterval(ttl - 1)))
            #expect(!store.tokenRefreshFailureIsCoolingDown(
                provider: .cursor, now: failure.attemptedAt.addingTimeInterval(ttl)))
            #expect(!store.tokenRefreshFailureIsCoolingDown(
                provider: .cursor, now: failure.attemptedAt.addingTimeInterval(-1)))
            store.tokenFetchFailureCooldowns[.cursor] = UsageStore.TokenFetchFailureCooldown(
                attemptedAt: Date().addingTimeInterval(-ttl - 1), scope: failure.scope)

            await store.refreshTokenUsageNow(for: .cursor, force: false)
            await store.refreshTokenUsageNow(for: .cursor, force: true)
            await fixture.settle()

            fixture.expectIdle(loadCount: 3)
            #expect(fixture.forced == [false, false, true])
            #expect(store.tokenSnapshot(for: .cursor) != nil)
            #expect(store.tokenError(for: .cursor) == nil)
            #expect(store.tokenFetchFailureCooldowns[.cursor] == nil)
        }
    }

    @Test(arguments: ["account", "manual-cookie", "history", "timezone", "config", "enablement", "cleanup"])
    func `a changed query scope is not blocked by a previous rejection`(_ change: String) async throws {
        try await Self.withFixture(fingerprint: "cookie-a", frequency: .fiveMinutes) { fixture in
            fixture.results = [
                .failure(CursorStatusProbeError.costRequestForbidden),
                .success(Self.snapshot("cookie-a")),
            ]
            let store = fixture.store
            await store.refreshTokenUsageNow(for: .cursor, force: false)
            switch change {
            case "account":
                fixture.fingerprint = "cookie-b"
                fixture.results[1] = .success(Self.snapshot("cookie-b"))
            case "manual-cookie":
                store.settings.cursorCookieSource = .manual
                store.settings.cursorCookieHeader = "WorkosCursorSessionToken=fixture-manual"
            case "history": store.settings.costUsageHistoryDays = 7
            case "timezone": store.settings.costUsageBucketTimeZoneIdentifier = "America/Los_Angeles"
            case "config":
                // The inactive manual header changes provider configuration without changing the auto scope string.
                store.settings.cursorCookieHeader = "WorkosCursorSessionToken=fixture-inactive"
            case "enablement":
                let metadata = store.metadata(for: .cursor)
                store.settings.setProviderEnabled(provider: .cursor, metadata: metadata, enabled: false)
                store.settings.setProviderEnabled(provider: .cursor, metadata: metadata, enabled: true)
            default: store.clearProviderRuntimeState(.cursor)
            }

            await store.refreshTokenUsageNow(for: .cursor, force: false)
            await fixture.settle()

            fixture.expectIdle(loadCount: 2)
            #expect(store.tokenSnapshot(for: .cursor) != nil)
            #expect(store.tokenFetchFailureCooldowns[.cursor] == nil)
        }
    }

    @Test
    func `a rejected old account cannot install a cooldown for its replacement`() async throws {
        try await Self.withFixture(fingerprint: "cookie-a", frequency: .fiveMinutes) { fixture in
            fixture.results = [
                .failure(CursorStatusProbeError.costRequestForbidden),
                .success(Self.snapshot("cookie-b")),
            ]
            fixture.onLoad = { count in
                if count == 1 { fixture.fingerprint = "cookie-b" }
            }
            await fixture.store.refreshTokenUsageNow(for: .cursor, force: false)
            await fixture.settle()

            fixture.expectIdle(loadCount: 2)
            #expect(fixture.forced == [false, true])
            #expect(fixture.store.tokenSnapshot(for: .cursor)?.credentialScopeFingerprint == "cookie-b")
            #expect(fixture.store.tokenFetchFailureCooldowns[.cursor] == nil)
        }
    }

    @Test
    func `a forced transient failure does not retain the previous forbidden cooldown`() async throws {
        try await Self.withFixture(fingerprint: "cookie-a", frequency: .fiveMinutes) { fixture in
            fixture.results = [
                .failure(CursorStatusProbeError.costRequestForbidden), .failure(FixtureError.failed),
                .success(Self.snapshot("cookie-a")),
            ]
            await fixture.store.refreshTokenUsageNow(for: .cursor, force: false)
            await fixture.store.refreshTokenUsageNow(for: .cursor, force: true)
            await fixture.store.refreshTokenUsageNow(for: .cursor, force: false)
            await fixture.settle()

            fixture.expectIdle(loadCount: 3)
            #expect(fixture.forced == [false, true, false])
            #expect(fixture.store.tokenSnapshot(for: .cursor) != nil)
        }
    }

    @Test
    func `timed out scans keep their cooldown without a published snapshot`() async throws {
        try await Self.withFixture(frequency: .fiveMinutes) { fixture in
            fixture.results = Array(repeating: .failure(CostUsageError.timedOut(seconds: 600)), count: 2)
            await fixture.store.refreshTokenUsageNow(for: .cursor, force: false)
            await fixture.store.refreshTokenUsageNow(for: .cursor, force: false)
            await fixture.settle()

            fixture.expectIdle(loadCount: 1)
            #expect(fixture.store.tokenSnapshot(for: .cursor) == nil)
        }
    }

    @Test
    func `manual cadence permits each explicitly requested attempt`() async throws {
        try await Self.withFixture { fixture in
            fixture.results = Array(repeating: .failure(CursorStatusProbeError.costRequestForbidden), count: 2)
            await fixture.store.refreshTokenUsageNow(for: .cursor, force: false)
            await fixture.store.refreshTokenUsageNow(for: .cursor, force: false)
            await fixture.settle()
            fixture.expectIdle(loadCount: 2)
        }
    }

    @Test(arguments: [false, true])
    func `cancellation discards a late forbidden or timeout failure`(timeout: Bool) async throws {
        try await Self.withFixture(fingerprint: "cookie-a", frequency: .fiveMinutes) { fixture in
            let error: Error = timeout
                ? CostUsageError.timedOut(seconds: 600)
                : CursorStatusProbeError.costRequestForbidden
            fixture.results = [.failure(error), .success(Self.snapshot("cookie-a"))]
            fixture.onLoad = { _ in fixture.store.tokenRefreshSequenceTask?.cancel() }
            await fixture.store.refreshTokenUsageNow(for: .cursor, force: false)
            await fixture.settle()

            #expect(fixture.store.tokenFetchFailureCooldowns[.cursor] == nil)
            #expect(fixture.store.tokenError(for: .cursor) == nil)
            #expect(fixture.store.lastTokenFetchAt[.cursor] == nil)
            fixture.onLoad = nil
            await fixture.store.refreshTokenUsageNow(for: .cursor, force: false)
            await fixture.settle()

            fixture.expectIdle(loadCount: 2)
            #expect(fixture.store.tokenSnapshot(for: .cursor) != nil)
        }
    }

    @Test
    func `cancelling a forced attempt permits normal recovery after the prior rejection`() async throws {
        try await Self.withFixture(fingerprint: "cookie-a", frequency: .fiveMinutes) { fixture in
            fixture.results = [
                .failure(CursorStatusProbeError.costRequestForbidden), .failure(CancellationError()),
                .success(Self.snapshot("cookie-a")),
            ]
            await fixture.store.refreshTokenUsageNow(for: .cursor, force: false)
            await fixture.store.refreshTokenUsageNow(for: .cursor, force: true)
            #expect(fixture.store.tokenFetchFailureCooldowns[.cursor] == nil)
            await fixture.store.refreshTokenUsageNow(for: .cursor, force: false)
            await fixture.settle()
            fixture.expectIdle(loadCount: 3)
        }
    }

    @Test
    func `clearing the cost cache permits another request after a rejection`() async throws {
        try await Self.withFixture(fingerprint: "cookie-a", frequency: .fiveMinutes) { fixture in
            let fileManager = CacheFileManager(root: fixture.root)
            let cache = UsageStore.costUsageCacheDirectory(fileManager: fileManager)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try Data("synthetic cache".utf8).write(to: cache.appendingPathComponent("sample"))
            let sentinel = fixture.root.appendingPathComponent("unrelated")
            try Data("keep".utf8).write(to: sentinel)
            fixture.results = [
                .failure(CursorStatusProbeError.costRequestForbidden),
                .success(Self.snapshot("cookie-a")),
            ]
            await fixture.store.refreshTokenUsageNow(for: .cursor, force: false)

            let root = fixture.root
            let error = await fixture.store.clearCostUsageCache(fileManagerFactory: { CacheFileManager(root: root) })
            #expect(error == nil)
            #expect(!FileManager.default.fileExists(atPath: cache.path))
            #expect(FileManager.default.fileExists(atPath: sentinel.path))
            #expect(fixture.store.tokenFetchFailureCooldowns[.cursor] == nil)
            await fixture.store.refreshTokenUsageNow(for: .cursor, force: false)
            await fixture.settle()
            fixture.expectIdle(loadCount: 2)
        }
    }

    @Test
    func `dashboard failures still wait for explicit refresh or a new publication or account`() async throws {
        try await Self.withFixture(fingerprint: "cookie-a", frequency: .fiveMinutes) { fixture in
            fixture.results = Array(repeating: .failure(CursorStatusProbeError.costRequestForbidden), count: 4)
            let store = fixture.store
            for _ in 0..<2 {
                _ = await SpendDashboardSource.makeRequest(
                    settings: store.settings,
                    store: store,
                    mode: .refreshMissing)
            }
            #expect(fixture.forced.count == 1)
            #expect(store.spendDashboardTokenSnapshotPublicationForCurrentConfig(for: .cursor) == nil)

            _ = await SpendDashboardSource.makeRequest(settings: store.settings, store: store, mode: .forceRefresh)
            #expect(fixture.forced.count == 2)
            store.publishTokenSnapshot(Self.snapshot("cookie-a"), for: .cursor)
            _ = await SpendDashboardSource.makeRequest(settings: store.settings, store: store, mode: .refreshMissing)
            #expect(fixture.forced.count == 3)
            fixture.fingerprint = "cookie-b"
            _ = await SpendDashboardSource.makeRequest(settings: store.settings, store: store, mode: .refreshMissing)

            fixture.expectIdle(loadCount: 4)
            #expect(store.spendDashboardTokenRefreshInFlight.isEmpty)
        }
    }

    @Test(arguments: [nil, "cookie-a"] as [String?])
    func `unchanged unconfirmed credentials reject once and allow the next ordinary refresh`(
        initialFingerprint: String?) async throws
    {
        try await Self.withFixture(fingerprint: initialFingerprint) { fixture in
            let store = fixture.store
            store.tokenErrors[.cursor] = "Previous cost failure"
            fixture.results = [.success(Self.snapshot("cookie-b")), .success(Self.snapshot("cookie-b"))]

            await store.refreshTokenUsageNow(for: .cursor, force: false)
            await fixture.settle()

            fixture.expectIdle(loadCount: 1)
            #expect(store.tokenSnapshotPublicationRevision(for: .cursor) == 0)
            #expect(store.tokenSnapshot(for: .cursor) == nil)
            #expect(store.tokenError(for: .cursor) == "Previous cost failure")
            #expect(store.lastTokenFetchAt[.cursor] == nil)
            #expect(store.lastTokenFetchScope[.cursor] == nil)
            guard store.tokenRefreshSequenceTask == nil else { return }

            await store.refreshTokenUsageNow(for: .cursor, force: false)
            await fixture.settle()

            fixture.expectIdle(loadCount: 2)
            #expect(fixture.forced == [false, false])
            #expect(store.tokenSnapshotPublicationRevision(for: .cursor) == 0)
            #expect(store.tokenError(for: .cursor) == "Previous cost failure")
        }
    }

    @Test
    func `rejecting a different fetched cookie preserves accepted current-account data`() async throws {
        try await Self.withFixture(fingerprint: "cookie-a") { fixture in
            let store = fixture.store
            let retained = Self.snapshot("cookie-a", cost: 0.5)
            store.installCachedTokenSnapshot(retained, for: .cursor)
            let publication = store.tokenSnapshotPublicationForCurrentProviderConfig(for: .cursor)
            let revision = store.tokenSnapshotPublicationRevision(for: .cursor)
            fixture.results = [.success(Self.snapshot("cookie-b", cost: 2))]

            await store.refreshTokenUsageNow(for: .cursor, force: false)
            await fixture.settle()

            fixture.expectIdle(loadCount: 1)
            #expect(store.tokenSnapshot(for: .cursor) == retained)
            #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .cursor) == publication)
            #expect(store.tokenSnapshotPublicationRevision(for: .cursor) == revision)
            #expect(store.lastTokenFetchAt[.cursor] == nil)
            #expect(store.lastTokenFetchScope[.cursor] == nil)
        }
    }

    @Test
    func `a successful fetch can confirm its initially unresolved cookie without a retry`() async throws {
        try await Self.withFixture { fixture in
            let fresh = Self.snapshot("cookie-a")
            fixture.results = [.success(fresh)]
            fixture.onLoad = { _ in fixture.fingerprint = "cookie-a" }

            await fixture.store.refreshTokenUsageNow(for: .cursor, force: false)
            await fixture.settle()

            fixture.expectIdle(loadCount: 1)
            #expect(fixture.store.tokenSnapshot(for: .cursor) == fresh)
            #expect(fixture.store.lastTokenFetchScope[.cursor]?.hasSuffix("auto:cookie-a") == true)
        }
    }

    @Test
    func `a real cookie change retries once and publishes only the current cookie`() async throws {
        try await Self.withFixture(fingerprint: "cookie-a") { fixture in
            let fresh = Self.snapshot("cookie-b", cost: 2)
            fixture.results = [.success(Self.snapshot("cookie-a")), .success(fresh)]
            fixture.onLoad = { count in
                if count == 1 { fixture.fingerprint = "cookie-b" }
            }

            await fixture.store.refreshTokenUsageNow(for: .cursor, force: false)
            await fixture.settle()

            fixture.expectIdle(loadCount: 2)
            #expect(fixture.forced == [false, true])
            #expect(fixture.store.tokenSnapshot(for: .cursor) == fresh)
            #expect(fixture.store.tokenSnapshotPublicationRevision(for: .cursor) == 1)
        }
    }

    @Test
    func `losing credential confirmation permits one replacement then stops`() async throws {
        try await Self.withFixture(fingerprint: "cookie-a") { fixture in
            fixture.results = [.success(Self.snapshot("cookie-a")), .success(Self.snapshot("cookie-a"))]
            fixture.onLoad = { _ in fixture.fingerprint = nil }

            await fixture.store.refreshTokenUsageNow(for: .cursor, force: false)
            await fixture.settle()

            fixture.expectIdle(loadCount: 2)
            #expect(fixture.forced == [false, true])
            #expect(fixture.store.tokenSnapshotPublicationRevision(for: .cursor) == 0)
        }
    }

    @Test(arguments: ["timezone", "history", "config"])
    func `cookie confirmation cannot hide changed cost or provider settings`(_ change: String) async throws {
        try await Self.withFixture { fixture in
            let fresh = Self.snapshot("cookie-a", cost: 2)
            fixture.results = [.success(Self.snapshot("cookie-a")), .success(fresh)]
            fixture.onLoad = { count in
                guard count == 1 else { return }
                fixture.fingerprint = "cookie-a"
                let settings = fixture.store.settings
                switch change {
                case "timezone": settings.costUsageBucketTimeZoneIdentifier = "America/Los_Angeles"
                case "history": settings.costUsageHistoryDays = 7
                default:
                    settings.setProviderEnabled(
                        provider: .cursor, metadata: fixture.store.metadata(for: .cursor), enabled: false)
                    settings.setProviderEnabled(
                        provider: .cursor, metadata: fixture.store.metadata(for: .cursor), enabled: true)
                }
            }

            await fixture.store.refreshTokenUsageNow(for: .cursor, force: false)
            await fixture.settle()

            fixture.expectIdle(loadCount: 2)
            #expect(fixture.forced == [false, true])
            #expect(fixture.store.tokenSnapshot(for: .cursor) == fresh)
            #expect(fixture.store.tokenSnapshotPublicationRevision(for: .cursor) == 1)
        }
    }

    @Test(arguments: [false, true])
    func `ordinary failure and cancellation do not enqueue credential retries`(_ cancelled: Bool) async throws {
        try await Self.withFixture { fixture in
            fixture.results = [.failure(cancelled ? CancellationError() : FixtureError.failed)]

            await fixture.store.refreshTokenUsageNow(for: .cursor, force: false)
            await fixture.settle()

            fixture.expectIdle(loadCount: 1)
            #expect(fixture.store.tokenSnapshot(for: .cursor) == nil)
            #expect(fixture.store
                .tokenError(for: .cursor) == (cancelled ? nil : FixtureError.failed.localizedDescription))
            if cancelled { #expect(fixture.store.lastTokenFetchAt[.cursor] == nil) }
        }
    }

    private static func snapshot(_ fingerprint: String, cost: Double = 1) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            meteredCostUSD: cost,
            credentialScopeFingerprint: fingerprint,
            daily: [],
            updatedAt: Date(timeIntervalSince1970: 100))
    }

    private static func forbiddenCostError() async throws -> Error {
        let url = try #require(URL(string: "https://cursor-cost.test"))
        let transport = ProviderHTTPTransportStub { request in
            let requestURL = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: requestURL, statusCode: 403, httpVersion: nil, headerFields: nil))
            return (Data(#"{"error":{"message":"Cursor is not available in your region."}}"#.utf8), response)
        }
        let fetcher = CursorUsageEventsFetcher(baseURL: url, transport: transport)
        do {
            _ = try await fetcher.fetchUsage(cookieHeader: "WorkosCursorSessionToken=fixture", since: nil, until: nil)
            Issue.record("Expected the synthetic forbidden response to reject cost usage")
            return FixtureError.failed
        } catch {
            return error
        }
    }

    private static func withFixture(
        fingerprint: String? = nil,
        frequency: RefreshFrequency = .manual,
        body: (Fixture) async throws -> Void) async throws
    {
        let fixture = try Fixture(fingerprint: fingerprint, frequency: frequency)
        do {
            try await body(fixture)
        } catch {
            await fixture.tearDown()
            throw error
        }
        await fixture.tearDown()
    }

    private enum FixtureError: LocalizedError {
        case failed
        var errorDescription: String? {
            "Synthetic cost failure"
        }
    }

    private final class CacheFileManager: FileManager, @unchecked Sendable {
        let root: URL

        init(root: URL) {
            self.root = root
            super.init()
        }

        override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
            directory == .cachesDirectory && domainMask == .userDomainMask ? [self.root] : []
        }

        override func removeItem(at url: URL) throws {
            let expected = self.root.appendingPathComponent("CodexBar/cost-usage", isDirectory: true)
            guard url.standardizedFileURL == expected.standardizedFileURL else {
                throw CocoaError(.fileWriteNoPermission)
            }
            try super.removeItem(at: url)
        }
    }

    @MainActor
    private final class Fixture {
        let store: UsageStore
        let root: URL
        var fingerprint: String?
        var results: [Result<CostUsageTokenSnapshot, Error>] = []
        var forced: [Bool] = []
        var onLoad: ((Int) -> Void)?
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var stopping = false

        init(fingerprint: String?, frequency: RefreshFrequency) throws {
            self.root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            self.fingerprint = fingerprint
            let settings = testSettingsStore(
                suiteName: "CursorCostRefreshRetryTests",
                userDefaults: InMemoryUserDefaults(),
                config: testConfigWithAllProvidersDisabled(),
                keychainAccessPolicy: .init(setDisabled: { _ in }, isExplicitlyDisabled: { false }))
            settings.costUsageEnabled = false
            settings.codexLocalSessionCostLedgerEnabled = false
            settings.costUsageHistoryDays = 30
            settings.costUsageBucketTimeZoneIdentifier = "UTC"
            settings.cursorCookieSource = .auto
            settings.refreshFrequency = frequency
            settings.openAIWebAccessEnabled = false
            settings.providerDetectionCompleted = true
            enableTestProviders([.cursor], settings: settings)
            let environment = ["HOME": self.root.path, "CODEX_HOME": self.root.appendingPathComponent("codex").path]
            self.store = UsageStore(
                fetcher: UsageFetcher(environment: environment),
                browserDetection: BrowserDetection(homeDirectory: self.root.path, cacheTTL: 0),
                settings: settings,
                startupBehavior: .testing,
                environmentBase: environment)
            self.store._test_widgetSnapshotSaveOverride = { _ in }
            self.store._test_cursorCostCredentialFingerprintOverride = { [weak self] in self?.fingerprint }
            self.store._test_tokenUsageSnapshotLoaderOverride = { [weak self] _, force, _, _, _ in
                guard let self, !self.stopping else { throw CancellationError() }
                self.forced.append(force)
                let count = self.forced.count
                // Park unexpected retries before indexing the fixture, including on unfixed code.
                if count > self.results.count {
                    await withCheckedContinuation { self.waiting.append($0) }
                }
                guard !self.stopping else { throw CancellationError() }
                self.onLoad?(count)
                return try self.results[count - 1].get()
            }
            settings.costUsageEnabled = true
        }

        func settle() async {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while self.store.tokenRefreshSequenceTask != nil, self.forced.count <= self.results.count,
                  ContinuousClock.now < deadline
            {
                await Task.yield()
            }
        }

        func expectIdle(loadCount: Int) {
            #expect(self.forced.count == loadCount)
            #expect(self.store.tokenRefreshRetryProviders.isEmpty)
            #expect(self.store.tokenRefreshSequenceTask == nil)
            #expect(self.store.tokenRefreshSequenceToken == nil)
            #expect(self.store.tokenRefreshSequenceProvider == nil)
            #expect(self.store.tokenRefreshInFlight.isEmpty)
            #expect(!self.store.pendingForcedTokenRefresh)
        }

        func tearDown() async {
            self.stopping = true
            self.store.settings.costUsageEnabled = false
            self.store.settings.codexLocalSessionCostLedgerEnabled = false
            let sequence = self.store.tokenRefreshSequenceTask
            sequence?.cancel()
            for continuation in self.waiting {
                continuation.resume()
            }
            self.waiting.removeAll()
            await sequence?.value
            await self.store.widgetSnapshotPersistTask?.value
            let relief = self.store.memoryPressureReliefTask
            relief?.cancel()
            await relief?.value
            self.store.tokenRefreshRetryProviders.removeAll()
            self.store._test_tokenUsageSnapshotLoaderOverride = nil
            self.store._test_cursorCostCredentialFingerprintOverride = nil
            self.onLoad = nil
            try? FileManager.default.removeItem(at: self.root)
        }
    }
}
