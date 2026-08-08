import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Crash-safety harness for the SQLite cost store. The `CodexBarCostStoreCrashProbe`
/// executable drives these entry points so tests can SIGKILL a real process at a
/// deterministic point inside `saveCodexCache` and then prove, from a fresh process, that
/// the interrupted save left no partial state behind. Fixtures live here (not in the test
/// target) so the probe subprocess and the asserting test share one source of truth.
package enum CostUsageStoreCrashHarness {
    static let scanWindow = (sinceKey: "0000-01-01", untilKey: "9999-12-31")

    /// Both processes must agree on the calendar: `loadCodexCache` discards the cache when
    /// the stored time zone differs from the caller's.
    static var fixtureCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func seededCache() -> CostUsageCache {
        var cache = CostUsageCache()
        cache.files = [
            "/sessions/a.jsonl": self.usage(session: "session-a", input: 1),
            "/sessions/b.jsonl": self.usage(session: "session-b", input: 2),
            "/sessions/c.jsonl": self.usage(session: "session-c", input: 3),
        ]
        cache.days = ["2026-08-01": ["gpt-5.6-sol": [6, 0, 0]]]
        return cache
    }

    /// Differs from the seed in every way a torn save could mix: changed tallies for kept
    /// files, one file removed, one added, and new global day totals.
    static func updatedCache() -> CostUsageCache {
        var cache = CostUsageCache()
        cache.files = [
            "/sessions/a.jsonl": self.usage(session: "session-a", input: 10),
            "/sessions/b.jsonl": self.usage(session: "session-b", input: 20),
            "/sessions/d.jsonl": self.usage(session: "session-d", input: 40),
        ]
        cache.days = ["2026-08-01": ["gpt-5.6-sol": [70, 0, 0]]]
        return cache
    }

    @discardableResult
    package static func seed(cacheRoot: URL) -> Bool {
        self.save(self.seededCache(), cacheRoot: cacheRoot, killAfterFiles: nil)
    }

    /// Saves the updated fixture. With `killAfterFiles` set, the process raises SIGKILL
    /// inside the save transaction once that many files have been persisted — after real
    /// table writes have been issued, before the cycle's aggregates and metadata.
    @discardableResult
    package static func saveUpdate(cacheRoot: URL, killAfterFiles: Int?) -> Bool {
        self.save(self.updatedCache(), cacheRoot: cacheRoot, killAfterFiles: killAfterFiles)
    }

    private static func save(_ cache: CostUsageCache, cacheRoot: URL, killAfterFiles: Int?) -> Bool {
        if let killAfterFiles {
            CostUsageStore.saveCycleCheckpointForTesting = { persistedFiles in
                if persistedFiles >= killAfterFiles {
                    kill(getpid(), SIGKILL)
                }
            }
        }
        let store = CostUsageStore(cacheRoot: cacheRoot)
        _ = store.syncSaveCodexCache(
            cache,
            calendar: self.fixtureCalendar,
            requestedScanWindow: self.scanWindow)
        return true
    }

    private static func usage(session: String, input: Int) -> CostUsageFileUsage {
        var usage = CostUsageFileUsage(
            mtimeUnixMs: 1000,
            size: 100,
            days: ["2026-08-01": ["gpt-5.6-sol": [input, 0, 0]]])
        usage.sessionId = session
        return usage
    }
}
