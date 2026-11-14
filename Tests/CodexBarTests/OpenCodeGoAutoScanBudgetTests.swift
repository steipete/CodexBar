#if os(macOS)

import Foundation
import SQLite3
import Testing
@testable import CodexBarCore

struct OpenCodeGoAutoScanBudgetTests {
    private struct StubClaudeFetcher: ClaudeUsageFetching {
        func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot { throw ClaudeUsageError
            .parseFailed("stub")
        }

        func debugRawProbe(model _: String) async -> String { "stub" }
        func detectVersion() -> String? { nil }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int {
            self.lock.withLock { self.count }
        }

        func increment() { self.lock.withLock { self.count += 1 } }
    }

    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            guard !self.opened else { return }
            await withCheckedContinuation { self.waiters.append($0) }
        }

        func release() {
            self.opened = true
            let pending = self.waiters
            self.waiters = []
            for waiter in pending {
                waiter.resume()
            }
        }
    }

    private enum SQLiteTestError: Error { case open, exec }
    private static let now = Date(timeIntervalSince1970: 1_772_798_400)

    @Test
    func `remote quota returns before history and the later refresh reuses one scan`() async throws {
        let env = try Self.makeDatabase()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let gate = Gate()
        let finished = AsyncStream<Void>.makeStream()
        defer { finished.continuation.finish() }
        let scans = Counter()
        let loader: OpenCodeGoLocalUsageFetchStrategy.LocalSnapshotLoader = { context in
            await gate.wait()
            let snapshot = try Self.read(reader, context: context, scans: scans)
            finished.continuation.yield(())
            return snapshot
        }
        let first = try await Self.strategy(loader: loader, budget: .zero).fetch(Self.makeContext())
        #expect(first.sourceLabel == "cli")
        #expect(first.usage.opencodegoUsage?.localHistoryPending == true)
        #expect(first.usage.primary?.usedPercent == 40)
        #expect(first.usage.dataConfidence != .estimated)
        #expect(first.usage.opencodegoUsage?.daily.isEmpty == true)
        #expect(scans.value == 0)
        await gate.release()
        var iterator = finished.stream.makeAsyncIterator()
        _ = await iterator.next()
        let second = try await Self.strategy(loader: loader).fetch(Self.makeContext())
        #expect(second.sourceLabel == "local+cli")
        #expect(second.usage.opencodegoUsage?.localHistoryPending == false)
        #expect(second.usage.primary?.usedPercent == 40)
        #expect(second.usage.opencodegoUsage?.daily.map(\.costUSD) == [3])
        #expect(scans.value == 1)
    }

    @Test
    func `small history finishes within the default budget`() async throws {
        let env = try Self.makeDatabase()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let scans = Counter()
        let result = try await Self.strategy(loader: { try Self.read(reader, context: $0, scans: scans) })
            .fetch(Self.makeContext())
        #expect(OpenCodeGoLocalUsageFetchStrategy.localHistoryScanBudget == .seconds(5))
        #expect(result.sourceLabel == "local+cli")
        #expect(result.usage.primary?.usedPercent == 40)
        #expect(result.usage.opencodegoUsage?.daily.map(\.costUSD) == [3])
        #expect(scans.value == 1)
    }

    @Test
    func `without remote quota the refresh waits for the original scan`() async throws {
        let env = try Self.makeDatabase()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let gate = Gate()
        let remoteAttempt = AsyncStream<Void>.makeStream()
        defer { remoteAttempt.continuation.finish() }
        let scans = Counter()
        let strategy = Self.strategy(
            loader: { context in
                await gate.wait()
                return try Self.read(reader, context: context, scans: scans)
            },
            budget: .zero,
            cliCredentialLoader: { _ in
                remoteAttempt.continuation.yield(())
                return nil
            })
        let refresh = Task { try await strategy.fetch(Self.makeContext()) }
        var iterator = remoteAttempt.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(scans.value == 0)
        await gate.release()
        let result = try await refresh.value
        #expect(result.sourceLabel == "local")
        #expect(result.usage.dataConfidence == .estimated)
        #expect(result.usage.primary?.usedPercent == 25)
        #expect(result.usage.opencodegoUsage?.daily.map(\.costUSD) == [3])
        #expect(scans.value == 1)
    }

    @Test
    func `cancelling a refresh still lets running history finish`() async throws {
        let gate = Gate()
        let remoteAttempt = AsyncStream<Void>.makeStream()
        let finished = AsyncStream<Void>.makeStream()
        defer { remoteAttempt.continuation.finish(); finished.continuation.finish() }
        let strategy = Self.strategy(
            loader: { _ in
                await gate.wait()
                #expect(Task.isCancelled)
                finished.continuation.yield(())
                throw OpenCodeGoLocalUsageError.notDetected
            },
            budget: .zero,
            cliCredentialLoader: { _ in
                remoteAttempt.continuation.yield(())
                return nil
            })
        let refresh = Task { try await strategy.fetch(Self.makeContext()) }
        var attempts = remoteAttempt.stream.makeAsyncIterator()
        _ = await attempts.next()
        refresh.cancel()
        await #expect(throws: CancellationError.self) { _ = try await refresh.value }
        await gate.release()
        var completions = finished.stream.makeAsyncIterator()
        _ = await completions.next()
    }

    @Test
    func `completed remote refresh cancels obsolete pending history work`() async throws {
        let gate = Gate()
        let started = AsyncStream<Void>.makeStream()
        let finished = AsyncStream<Void>.makeStream()
        defer { started.continuation.finish(); finished.continuation.finish() }
        let cancellations = Counter()
        let quota = try OpenCodeGoUsageFetcher.parseAPIUsage(
            text: #"{"usage":{"rolling":{"percent":40}}}"#, now: Self.now)
        let strategy = OpenCodeGoLocalUsageFetchStrategy(
            localSnapshotLoader: { _ in
                await withTaskCancellationHandler {
                    started.continuation.yield(())
                    await gate.wait()
                    finished.continuation.yield(())
                    return quota
                } onCancel: {
                    cancellations.increment()
                }
            },
            apiUsageOverlayFetcher: { _, _ in
                var iterator = started.stream.makeAsyncIterator()
                _ = await iterator.next()
                return quota
            },
            cliCredentialLoader: { _ in "cli-access" },
            localHistoryJoinTimeout: .zero)
        let result = try await strategy.fetch(Self.makeContext())
        #expect(result.usage.primary?.usedPercent == 40)
        #expect(cancellations.value == 1)
        await gate.release()
        var iterator = finished.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    private static func read(
        _ reader: OpenCodeGoLocalUsageReader,
        context: ProviderFetchContext,
        scans: Counter) throws -> OpenCodeGoUsageSnapshot
    {
        let observer: @Sendable () -> Void = { scans.increment() }
        return try OpenCodeGoLocalUsageReader.$scanObserverForTesting.withValue(observer) {
            try reader.fetch(now: Self.now, historyDays: context.costUsageHistoryDays)
        }
    }

    private static func strategy(
        loader: @escaping OpenCodeGoLocalUsageFetchStrategy.LocalSnapshotLoader,
        budget: Duration = OpenCodeGoLocalUsageFetchStrategy.localHistoryScanBudget,
        cliCredentialLoader: @escaping OpenCodeGoSettingsReader.CLICredentialLoader = { _ in "cli-access" })
        -> OpenCodeGoLocalUsageFetchStrategy
    {
        OpenCodeGoLocalUsageFetchStrategy(
            localSnapshotLoader: loader,
            webUsageOverlayFetcher: { _, _ in
                Issue.record("Cookie source Off must not request a browser session")
                return nil
            },
            apiUsageOverlayFetcher: { _, token in
                #expect(token == "cli-access")
                return try OpenCodeGoUsageFetcher.parseAPIUsage(
                    text: #"{"usage":{"rolling":{"percent":40}}}"#, now: Self.now)
            },
            cliCredentialLoader: cliCredentialLoader,
            localHistoryJoinTimeout: budget)
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
