#if os(macOS)

import Foundation
import SQLite3
import Testing
@testable import CodexBarCore

struct OpenCodeGoAutoScanBudgetTests {
    private struct StubClaudeFetcher: ClaudeUsageFetching {
        func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
            throw ClaudeUsageError.parseFailed("stub")
        }

        func debugRawProbe(model _: String) async -> String {
            "stub"
        }

        func detectVersion() -> String? {
            nil
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            self.lock.withLock { self.count }
        }

        func increment() {
            self.lock.withLock { self.count += 1 }
        }
    }

    private enum SQLiteTestError: Error {
        case open
        case exec
    }

    private static let now = Date(timeIntervalSince1970: 1_772_798_400)

    @Test
    func `exhausted auto scan budget returns remote quota and a later refresh reuses the finished scan`() async throws {
        let env = try Self.makeDatabase()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let scans = Counter()
        let completedScans = Counter()
        let release = DispatchSemaphore(value: 0)
        let pipeline = Self.pipeline(reader: reader, budget: .milliseconds(100), completedScans: completedScans)
        let observer: @Sendable () -> Void = {
            scans.increment()
            // A cold history scan that outlasts the refresh budget.
            _ = release.wait(timeout: .now() + 3)
        }

        try await OpenCodeGoLocalUsageReader.$scanObserverForTesting.withValue(observer) {
            let started = ContinuousClock.now
            let first = await pipeline.fetch(context: Self.makeContext(), provider: .opencodego)
            let elapsed = started.duration(to: ContinuousClock.now)
            let quota = try first.result.get()

            #expect(elapsed < .seconds(1))
            #expect(first.attempts.map(\.strategyID) == ["opencodego.local"])
            #expect(quota.sourceLabel == "cli")
            #expect(quota.usage.primary?.usedPercent == 40)
            #expect(quota.usage.dataConfidence != .estimated)
            // Unfinished local work is never published as history.
            #expect(quota.usage.opencodegoUsage?.daily.isEmpty == true)
            #expect(completedScans.value == 0)

            release.signal()
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while completedScans.value == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(completedScans.value == 1)

            let second = try await pipeline.fetch(context: Self.makeContext(), provider: .opencodego).result.get()
            #expect(second.sourceLabel == "local+cli")
            #expect(second.usage.primary?.usedPercent == 40)
            #expect(second.usage.opencodegoUsage?.daily.map(\.costUSD) == [3])
        }
        #expect(scans.value == 1)
    }

    @Test
    func `small history completes within the auto scan budget`() async throws {
        let env = try Self.makeDatabase()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let scans = Counter()
        let pipeline = Self.pipeline(
            reader: reader,
            budget: OpenCodeGoLocalUsageFetchStrategy.localHistoryScanBudget,
            completedScans: Counter())
        let observer: @Sendable () -> Void = { scans.increment() }

        let outcome = await OpenCodeGoLocalUsageReader.$scanObserverForTesting.withValue(observer) {
            await pipeline.fetch(context: Self.makeContext(), provider: .opencodego)
        }
        let result = try outcome.result.get()

        #expect(OpenCodeGoLocalUsageFetchStrategy.localHistoryScanBudget == .seconds(5))
        #expect(outcome.attempts.map(\.strategyID) == ["opencodego.local"])
        #expect(result.sourceLabel == "local+cli")
        #expect(result.usage.primary?.usedPercent == 40)
        #expect(result.usage.opencodegoUsage?.daily.map(\.costUSD) == [3])
        #expect(scans.value == 1)
    }

    @Test
    func `exhausted auto scan budget without remote quota falls through without local history`() async throws {
        let env = try Self.makeDatabase()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let pipeline = Self.pipeline(
            reader: reader,
            budget: .milliseconds(100),
            completedScans: Counter(),
            cliCredential: nil)
        let observer: @Sendable () -> Void = { _ = release.wait(timeout: .now() + 3) }

        let started = ContinuousClock.now
        let outcome = await OpenCodeGoLocalUsageReader.$scanObserverForTesting.withValue(observer) {
            await pipeline.fetch(context: Self.makeContext(), provider: .opencodego)
        }

        #expect(started.duration(to: ContinuousClock.now) < .seconds(1))
        #expect(outcome.attempts.map(\.strategyID) == ["opencodego.local", "opencodego.web", "opencodego.api"])
        #expect(throws: OpenCodeGoSettingsError.self) { try outcome.result.get() }
    }

    private static func pipeline(
        reader: OpenCodeGoLocalUsageReader,
        budget: Duration,
        completedScans: Counter,
        cliCredential: String? = "cli-access") -> ProviderFetchPipeline
    {
        let quota: @Sendable (ProviderFetchContext, String) async throws -> OpenCodeGoUsageSnapshot = { _, token in
            #expect(token == "cli-access")
            return try OpenCodeGoUsageFetcher.parseAPIUsage(
                text: #"{"usage":{"rolling":{"percent":40}}}"#,
                now: Self.now)
        }
        let local = OpenCodeGoLocalUsageFetchStrategy(
            localSnapshotLoader: { context in
                defer { completedScans.increment() }
                return try reader.fetch(now: Self.now, historyDays: context.costUsageHistoryDays)
            },
            webUsageOverlayFetcher: { _, _ in
                Issue.record("Cookie source Off must not request a browser session")
                return nil
            },
            apiUsageOverlayFetcher: quota,
            cliCredentialLoader: { _ in cliCredential },
            localHistoryJoinTimeout: budget)
        let strategies: [any ProviderFetchStrategy] = [
            local,
            OpenCodeGoUsageFetchStrategy(),
            OpenCodeGoAPIUsageFetchStrategy(cliCredentialLoader: { _ in cliCredential }, usageFetcher: quota),
        ]
        return ProviderFetchPipeline(resolveStrategies: { _ in strategies })
    }

    private static func makeContext() -> ProviderFetchContext {
        // Cookie source Off keeps browser discovery out of the test; the CLI login stays usable.
        let settings = ProviderSettingsSnapshot.make(opencodego: .init(
            cookieSource: .off,
            manualCookieHeader: nil,
            workspaceID: nil))
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: settings,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }

    private static func makeDatabase() throws -> (root: URL, authURL: URL, databaseURL: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodeGoAutoScanBudgetTests-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent(".local/share/opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("opencode.db", isDirectory: false)
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }
        let createdMs = Int64(Self.now.timeIntervalSince1970 * 1000) - 60 * 60 * 1000
        let sql = """
        CREATE TABLE message (
          id TEXT PRIMARY KEY, session_id TEXT NOT NULL, data TEXT NOT NULL,
          time_created INTEGER, time_updated INTEGER);
        INSERT INTO message VALUES ('msg-1', 'session-1',
          '{"providerID":"opencode-go","role":"assistant","cost":3,"time":{"created":\(createdMs)}}',
          \(createdMs), \(createdMs));
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SQLiteTestError.exec }
        return (root, directory.appendingPathComponent("auth.json", isDirectory: false), databaseURL)
    }
}

#endif
