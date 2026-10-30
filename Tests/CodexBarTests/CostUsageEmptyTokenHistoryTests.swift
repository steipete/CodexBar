import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageEmptyTokenHistoryTests {
    /// A persisted empty token history is stored as `hasTokenSnapshots = true` with zero snapshot rows. The scan
    /// baseline decodes it as unloaded (`nil`), hydration restores `[]`, and the identical-content comparison sees
    /// `nil != []`, so every warm pass takes the full save path and the next pass decodes the whole store again.
    @Test
    func `persisted empty token history keeps warm passes on the identical save path`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 1)
        let iso = env.isoString(for: day)
        let session = "empty-history-session"
        // A session that aborted before any usage, then continued in a second rollout file.
        _ = try env.writeCodexSessionFile(day: day, filename: "rollout-a-\(session).jsonl", contents: [
            #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"id":"\#(session)"}}"#,
            #"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"gpt-5.4"}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso)","payload":{"type":"token_count","info":null}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso)","payload":{"type":"turn_aborted"}}"#,
        ].joined(separator: "\n") + "\n")
        _ = try env.writeCodexSessionFile(day: day, filename: "rollout-b-\(session).jsonl", contents: [
            #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"id":"\#(session)"}}"#,
            #"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"gpt-5.4"}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso)","payload":{"type":"token_count","#
                + #""info":{"total_token_usage":{"input_tokens":40,"cached_input_tokens":4,"output_tokens":9}}}}"#,
        ].joined(separator: "\n") + "\n")
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-trace.sqlite"))
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(provider: .codex, since: day, until: day, now: day, options: options)

        // Recreate the stored state observed in a real cache: an explicit empty history for the aborted file.
        var cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot, home: env.codexStoreHome)
        let aborted = try #require(cache.files.keys.first { $0.contains("rollout-a-") })
        cache.files[aborted]?.codexTokenSnapshots = []
        cache.files[aborted]?.codexTokenCheckpoints = []
        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, home: env.codexStoreHome, cache: cache)

        let store = CostUsageStore(cacheRoot: env.cacheRoot, home: env.codexStoreHome)
        let loaded = store.syncLoadCodexScan(calendar: options.calendar)
        loaded.release()
        var writes: [Int] = []
        for pass in 1...3 {
            let before = await store.persistenceWriteMetricsForTesting()
            var hooks = CostUsageStoreTestHooks.current
            hooks.scanStoreOverride = store
            CostUsageStoreTestHooks.$current.withValue(hooks) {
                env.evictSharedScanStores(except: store, calendar: options.calendar)
                _ = CostUsageScanner.loadDailyReport(
                    provider: .codex,
                    since: day,
                    until: day,
                    now: day.addingTimeInterval(Double(pass)),
                    options: options)
            }
            let after = await store.persistenceWriteMetricsForTesting()
            writes.append(after.rows - before.rows)
        }
        print("[empty-history] warm_pass_writes=\(writes)")
        #expect(writes.allSatisfy { $0 == 1 })
    }
}

extension CostUsageTestEnvironment {
    func evictSharedScanStores(except store: CostUsageStore, calendar: Calendar) {
        for index in 0..<5 {
            let competing = CostUsageStoreAccess.load(
                cacheRoot: self.root.appendingPathComponent("competing-cache-\(index)"),
                calendar: calendar)
            #expect(competing.store !== store)
            competing.release()
        }
    }
}

extension CostUsageEmptyTokenHistoryTests {
    @Test(arguments: [2, 16], [false, true])
    func `empty hydration changes only freshness metadata`(fileCount: Int, storedEmpty: Bool) async throws {
        let fixture = try ReadWorkFixture(fileCount: fileCount, rowsPerFile: 4)
        defer { fixture.remove() }
        let path = try #require(fixture.canonical.files.keys.min())
        var seed = fixture.canonical
        seed.files[path]?.codexTokenSnapshots = storedEmpty ? [] : nil
        seed.files[path]?.codexTokenCheckpoints = storedEmpty ? [] : nil
        #expect(!fixture.save(seed).catchUpRequired)
        for _ in 0..<3 {
            let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
            defer { loaded.release() }
            var incoming = loaded.cache
            incoming.files[path]?.codexTokenSnapshots = []
            incoming.files[path]?.codexTokenCheckpoints = []
            incoming.lastScanUnixMs += 1000
            let before = await fixture.store.persistenceWriteMetricsForTesting()
            #expect(!fixture.save(incoming, load: loaded).catchUpRequired)
            let after = await fixture.store.persistenceWriteMetricsForTesting()
            #expect(after.rows - before.rows == 1)
            #expect(await fixture.store.fetchTokenSnapshots(path: path).isEmpty)
        }
        #expect(fixture.store.syncLoadCodexCache(calendar: fixture.calendar).days == fixture.canonical.days)
    }

    @Test
    func `clearing a nonempty stored history still deletes its rows`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let path = try #require(fixture.canonical.files.keys.min())
        let sibling = try #require(fixture.canonical.files.keys.max())
        #expect(await fixture.store.fetchTokenSnapshots(path: path).count == 4)
        let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { loaded.release() }
        var incoming = loaded.cache
        incoming.files[path]?.codexTokenSnapshots = []
        incoming.files[path]?.codexTokenCheckpoints = []
        #expect(!fixture.save(incoming, load: loaded).catchUpRequired)
        #expect(await fixture.store.fetchTokenSnapshots(path: path).isEmpty)
        #expect(await fixture.store.fetchTokenSnapshots(path: sibling).count == 4)
        #expect(fixture.store.syncLoadCodexCache(calendar: fixture.calendar).days == fixture.canonical.days)
    }
}
