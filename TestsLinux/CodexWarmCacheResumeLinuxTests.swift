import Foundation
import Testing
@testable import CodexBarCore

/// A Codex session resumed in an older date partition must keep being counted.
///
/// Candidate files come from three sources: the day directories inside the scan
/// window, the flat root, and paths already present in `cache.files`. The
/// mtime-based lookback that would otherwise catch a rollout living outside the
/// window is gated behind `cache.files.isEmpty || plan.rootsChanged`, i.e. cold
/// cache only. A rollout that was never scanned and sits in an out-of-window
/// partition therefore stays invisible on every warm refresh.
struct CodexWarmCacheResumeLinuxTests {
    private struct Environment {
        let root: URL
        let cacheRoot: URL
        let codexSessionsRoot: URL

        init() throws {
            self.root = FileManager.default.temporaryDirectory
                .appendingPathComponent("codexbar-warm-resume-\(UUID().uuidString)", isDirectory: true)
            self.cacheRoot = self.root.appendingPathComponent("cache", isDirectory: true)
            self.codexSessionsRoot = self.root.appendingPathComponent("sessions", isDirectory: true)
            try FileManager.default.createDirectory(at: self.cacheRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: self.codexSessionsRoot, withIntermediateDirectories: true)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: self.root)
        }

        func localNoon(year: Int, month: Int, day: Int) throws -> Date {
            var comps = DateComponents()
            comps.calendar = Calendar.current
            comps.timeZone = TimeZone.current
            comps.year = year
            comps.month = month
            comps.day = day
            comps.hour = 12
            guard let date = comps.date else {
                throw NSError(domain: "CodexWarmCacheResumeLinuxTests", code: 1)
            }
            return date
        }

        func isoString(for date: Date) -> String {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime]
            return fmt.string(from: date)
        }

        /// Writes into the `YYYY/MM/DD` partition for `day`, like Codex does.
        @discardableResult
        func writeSession(day: Date, filename: String, contents: String) throws -> URL {
            let comps = Calendar.current.dateComponents([.year, .month, .day], from: day)
            let dir = self.codexSessionsRoot
                .appendingPathComponent(String(format: "%04d", comps.year ?? 1970), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", comps.month ?? 1), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", comps.day ?? 1), isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let fileURL = dir.appendingPathComponent(filename)
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        }

        func jsonl(_ objects: [[String: Any]]) throws -> String {
            try objects
                .map { try String(decoding: JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
                .joined(separator: "\n") + "\n"
        }
    }

    private static let model = "openai/gpt-5.2-codex"

    private static func turnContext(iso: String) -> [String: Any] {
        ["type": "turn_context", "timestamp": iso, "payload": ["model": self.model]]
    }

    private static func tokenCount(iso: String, input: Int, cached: Int, output: Int) -> [String: Any] {
        [
            "type": "event_msg",
            "timestamp": iso,
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": input,
                        "cached_input_tokens": cached,
                        "output_tokens": output,
                        "reasoning_output_tokens": 0,
                    ],
                    "model": self.model,
                ],
            ],
        ]
    }

    private static func totalTokens(_ report: CostUsageDailyReport) -> Int {
        report.data.reduce(0) { $0 + ($1.totalTokens ?? 0) }
    }

    private static func persistedCache(cacheRoot: URL) throws -> CostUsageCache {
        CostUsageStoreAccess.read(cacheRoot: cacheRoot)
    }

    @Test
    func `a session resumed in an older partition keeps being counted on a warm cache`() throws {
        let env = try Environment()
        defer { env.cleanup() }

        // "Today" for the scan, and a session that started outside a short history
        // window. The gap stays inside `codexActiveSessionLookbackDays`, which is the
        // range the active-session lookback is designed to cover.
        let today = try env.localNoon(year: 2026, month: 7, day: 20)
        let oldDay = try env.localNoon(year: 2026, month: 7, day: 1)
        let windowStart = try env.localNoon(year: 2026, month: 7, day: 15)

        // An in-window session, so the cache is warm (cache.files is not empty) and
        // the cold-cache lookback does not run on later refreshes.
        try env.writeSession(
            day: today,
            filename: "rollout-recent.jsonl",
            contents: env.jsonl([
                Self.turnContext(iso: env.isoString(for: today)),
                Self.tokenCount(iso: env.isoString(for: today), input: 100, cached: 0, output: 10),
            ]))

        // The resumed session: its rollout lives in an old partition.
        let oldFile = try env.writeSession(
            day: oldDay,
            filename: "rollout-resumed.jsonl",
            contents: env.jsonl([
                Self.turnContext(iso: env.isoString(for: oldDay)),
                Self.tokenCount(iso: env.isoString(for: oldDay), input: 50, cached: 0, output: 5),
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        // Warm the cache over the short window. The old rollout is out of window and
        // is not expected to appear here.
        let warmup = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: windowStart,
            until: today,
            now: today,
            options: options)
        let warmupTotal = Self.totalTokens(warmup)

        // The user resumes that old session: Codex appends to the original file, in
        // its original partition. The appended turn is dated today.
        let resumeISO = env.isoString(for: today.addingTimeInterval(60))
        try (env.jsonl([
            Self.turnContext(iso: env.isoString(for: oldDay)),
            Self.tokenCount(iso: env.isoString(for: oldDay), input: 50, cached: 0, output: 5),
            Self.turnContext(iso: resumeISO),
            Self.tokenCount(iso: resumeISO, input: 4000, cached: 0, output: 400),
        ])).write(to: oldFile, atomically: true, encoding: .utf8)

        let afterResume = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: windowStart,
            until: today,
            now: today.addingTimeInterval(120),
            options: options)

        // A forced rescan re-arms the cold path and sees everything, which is the
        // reference value the warm refresh should match.
        var forcedOptions = options
        forcedOptions.forceRescan = true
        let forced = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: windowStart,
            until: today,
            now: today.addingTimeInterval(180),
            options: forcedOptions)

        let resumedTokens = Self.totalTokens(forced) - warmupTotal
        #expect(resumedTokens > 0, "fixture sanity: the forced rescan must observe the resumed turn")

        // The warm refresh must not silently drop the resumed session's new tokens.
        #expect(
            Self.totalTokens(afterResume) == Self.totalTokens(forced),
            """
            warm refresh reported \(Self.totalTokens(afterResume)) tokens but a forced rescan \
            reported \(Self.totalTokens(forced)); the resumed session in an older partition was \
            never re-scanned
            """)
    }

    @Test
    func `older partition discovery shares the bounded scan budget`() throws {
        let env = try Environment()
        defer { env.cleanup() }

        let today = try env.localNoon(year: 2026, month: 7, day: 20)
        let oldDay = try env.localNoon(year: 2026, month: 7, day: 1)
        let windowStart = try env.localNoon(year: 2026, month: 7, day: 15)
        try env.writeSession(
            day: today,
            filename: "rollout-recent.jsonl",
            contents: env.jsonl([
                Self.turnContext(iso: env.isoString(for: today)),
                Self.tokenCount(iso: env.isoString(for: today), input: 100, cached: 0, output: 10),
            ]))
        let oldFile = try env.writeSession(
            day: oldDay,
            filename: "rollout-resumed.jsonl",
            contents: env.jsonl([
                Self.turnContext(iso: env.isoString(for: oldDay)),
                Self.tokenCount(iso: env.isoString(for: oldDay), input: 50, cached: 0, output: 5),
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        let warmup = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: windowStart,
            until: today,
            now: today,
            options: options)

        let resumeISO = env.isoString(for: today.addingTimeInterval(60))
        try env.jsonl([
            Self.turnContext(iso: env.isoString(for: oldDay)),
            Self.tokenCount(iso: env.isoString(for: oldDay), input: 50, cached: 0, output: 5),
            Self.turnContext(iso: resumeISO),
            Self.tokenCount(iso: resumeISO, input: 4000, cached: 0, output: 400),
        ]).write(to: oldFile, atomically: true, encoding: .utf8)

        // Ten units cannot reach the old partition in one pass. The persisted cursor must
        // advance rather than restarting at the oldest lookback day on every refresh.
        options.maxCodexScanBytesPerRefresh = 10
        let firstBudgeted = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: windowStart,
            until: today,
            now: today.addingTimeInterval(120),
            options: options)
        #expect(Self.totalTokens(firstBudgeted) == Self.totalTokens(warmup))
        let firstState = try #require(
            Self.persistedCache(cacheRoot: env.cacheRoot).codexActiveLookbackState)
        let sessionsRootPath = env.codexSessionsRoot.standardizedFileURL.path
        let firstNextDay = try #require(firstState.nextDayKeyByRoot[sessionsRootPath])
        #expect(!firstState.pendingFilePaths.contains(oldFile.standardizedFileURL.path))

        let secondBudgeted = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: windowStart,
            until: today,
            now: today.addingTimeInterval(180),
            options: options)
        #expect(Self.totalTokens(secondBudgeted) == Self.totalTokens(warmup))
        let secondState = try #require(
            Self.persistedCache(cacheRoot: env.cacheRoot).codexActiveLookbackState)
        #expect(secondState.nextDayKeyByRoot[sessionsRootPath].map { $0 > firstNextDay } == true)
        #expect(secondState.pendingFilePaths.contains(oldFile.standardizedFileURL.path))

        options.maxCodexScanBytesPerRefresh = 512 * 1024 * 1024
        let caughtUp = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: windowStart,
            until: today,
            now: today.addingTimeInterval(240),
            options: options)
        var forcedOptions = options
        forcedOptions.forceRescan = true
        let forced = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: windowStart,
            until: today,
            now: today.addingTimeInterval(300),
            options: forcedOptions)
        #expect(Self.totalTokens(caughtUp) == Self.totalTokens(forced))
    }
}
