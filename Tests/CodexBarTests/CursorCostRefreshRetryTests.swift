import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct CursorCostRefreshRetryTests {
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

    private static func withFixture(
        fingerprint: String? = nil,
        body: (Fixture) async throws -> Void) async throws
    {
        let fixture = try Fixture(fingerprint: fingerprint)
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

        init(fingerprint: String?) throws {
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
            settings.refreshFrequency = .manual
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
