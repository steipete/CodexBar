import Foundation
import Testing
@testable import CodexBarCore
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

@Suite(.serialized)
struct CostUsageCodexHomeStoreTests {
    @Test
    func `alternating codex homes keep their own coverage totals and pending work`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let homeA = env.root.appendingPathComponent("home-a", isDirectory: true)
        let homeB = env.root.appendingPathComponent("home-b", isDirectory: true)
        for index in 0..<3 {
            try Self.writeSession(home: homeA, env: env, day: day, name: "a-\(index).jsonl", tokens: 100 + index)
            try Self.writeSession(home: homeB, env: env, day: day, name: "b-\(index).jsonl", tokens: 10 + index)
        }

        var unbounded = CostUsageScanner.Options(
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        unbounded.refreshMinIntervalSeconds = 0
        var bounded = unbounded
        bounded.maxCodexSessionFileBytes = 1
        bounded.maxCodexScanBytesPerRefresh = 1

        let establishedA = try await Self.establish(home: homeA, now: day, options: unbounded)
        #expect(establishedA.historyCoverageIsEstablished)
        #expect(establishedA.sessionTokens == 303)

        let pendingB = try await Self.snapshot(home: homeB, now: day.addingTimeInterval(1), options: bounded)
        #expect(!pendingB.historyCoverageIsEstablished)
        let fetcher = CostUsageFetcher(cacheRoot: env.cacheRoot)
        let statusB = await fetcher.codexScanCatchUpStatus(codexHomePath: homeB.path, historyDays: 1, now: day)
        #expect(statusB.pending)

        // A first scan after lost state is never established, so this needs A's retained scan state.
        let againA = try await Self.snapshot(home: homeA, now: day.addingTimeInterval(2), options: unbounded)
        #expect(againA.historyCoverageIsEstablished)
        #expect(againA.sessionTokens == establishedA.sessionTokens)
        #expect(againA.last30DaysTokens == establishedA.last30DaysTokens)

        let statusBAfterA = await fetcher.codexScanCatchUpStatus(
            codexHomePath: homeB.path,
            historyDays: 1,
            now: day)
        #expect(statusBAfterA.pending)
        #expect(statusBAfterA.progressKey == statusB.progressKey)

        let finishedB = try await Self.establish(home: homeB, now: day.addingTimeInterval(3), options: unbounded)
        #expect(finishedB.historyCoverageIsEstablished)
        #expect(finishedB.sessionTokens == 33)
        let finalA = try await Self.snapshot(home: homeA, now: day.addingTimeInterval(4), options: unbounded)
        #expect(finalA.historyCoverageIsEstablished)
        #expect(finalA.sessionTokens == establishedA.sessionTokens)
    }

    @Test
    func `custom home session request details load from the shared store`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let home = env.root.appendingPathComponent("home-detail", isDirectory: true)
        try Self.writeSession(home: home, env: env, day: day, name: "detail.jsonl", tokens: 77, sessionID: "detail")

        let options = Self.options(Self.unboundedOptions(env: env), home: home)
        let fresh = try await Self.establish(home: home, now: day, options: options)
        let freshSession = try #require(fresh.sessions.first)
        let cached = try #require(await CostUsageFetcher.loadCachedCodexTokenSnapshot(
            now: day,
            codexHomePath: home.path,
            historyDays: 1,
            allowScopedCodexHome: true,
            includePiSessions: false,
            scannerOptions: options))
        let cachedSession = try #require(cached.sessions.first)

        let homeDatabase = CostUsageStore.databaseURL(cacheRoot: env.cacheRoot)
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        for session in [freshSession, cachedSession] {
            let source = try #require(session.requestDetailSource)
            #expect(source.databaseURL == homeDatabase)
            let turns = try await CostUsageSessionDetailLoader.load(
                source: source,
                lastActivity: session.lastActivity,
                range: start..<start.addingTimeInterval(86400),
                timeZone: calendar.timeZone)
            #expect(turns.compactMap(\.totalTokens).reduce(0, +) == 77)
        }
    }

    @Test
    func `default codex home keeps the shared database file`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        try Self.writeSession(home: env.codexHomeRoot, env: env, day: day, name: "default.jsonl", tokens: 42)

        var options = CostUsageScanner.Options(
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        let snapshot = try await Self.snapshot(home: env.codexHomeRoot, now: day, options: options)
        #expect(snapshot.sessionTokens == 42)

        let costUsageDirectory = CostUsageStore.databaseURL(cacheRoot: env.cacheRoot).deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: CostUsageStore.databaseURL(cacheRoot: env.cacheRoot).path))
        #expect(!FileManager.default.fileExists(
            atPath: costUsageDirectory.appendingPathComponent("codex-homes").path))
        options.codexSessionsRoot = env.codexSessionsRoot
        #expect(CostUsageStore(cacheRoot: options.cacheRoot, home: CodexHomeCostStoreScope.key(options: options))
            .databaseURL == CostUsageStore.databaseURL(cacheRoot: env.cacheRoot))
    }
}

extension CostUsageCodexHomeStoreTests {
    private static func options(_ options: CostUsageScanner.Options, home: URL) -> CostUsageScanner.Options {
        var options = options
        options.codexSessionsRoot = home.appendingPathComponent("sessions", isDirectory: true)
        return options
    }

    private static func unboundedOptions(env: CostUsageTestEnvironment) -> CostUsageScanner.Options {
        var options = CostUsageScanner.Options(
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        return options
    }

    /// The first full scan records the lookback; the next one confirms coverage.
    private static func establish(
        home: URL,
        now: Date,
        options: CostUsageScanner.Options) async throws -> CostUsageTokenSnapshot
    {
        var snapshot = try await Self.snapshot(home: home, now: now, options: options)
        for _ in 0..<2 where !snapshot.historyCoverageIsEstablished {
            snapshot = try await Self.snapshot(home: home, now: now, options: options)
        }
        return snapshot
    }

    private static func snapshot(
        home: URL,
        now: Date,
        options: CostUsageScanner.Options) async throws -> CostUsageTokenSnapshot
    {
        try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            codexHomePath: home.path,
            historyDays: 1,
            allowPricingRefresh: false,
            includePiSessions: false,
            bypassScannerDebounce: true,
            scannerOptions: options)
    }

    private static func writeSession(
        home: URL,
        env: CostUsageTestEnvironment,
        day: Date,
        name: String,
        tokens: Int,
        sessionID: String? = nil) throws
    {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: day)
        let directory = home
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(String(format: "%04d", comps.year ?? 1970), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", comps.month ?? 1), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", comps.day ?? 1), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = "openai/gpt-5.4"
        let meta: [[String: Any]] = sessionID.map {
            [["type": "session_meta", "timestamp": env.isoString(for: day), "payload": ["id": $0]]]
        } ?? []
        try env.jsonl(meta + [
            ["type": "turn_context", "timestamp": env.isoString(for: day), "payload": ["model": model]],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: day.addingTimeInterval(1)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "model": model,
                        "last_token_usage": ["input_tokens": tokens, "cached_input_tokens": 0, "output_tokens": 0],
                    ],
                ],
            ],
        ]).write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}
