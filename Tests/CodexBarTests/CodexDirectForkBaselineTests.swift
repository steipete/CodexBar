import Foundation
import Testing
@testable import CodexBarCore

struct CodexDirectForkBaselineTests {
    @Test(arguments: [0, 3, 8], [false, true])
    func `direct fork chains preserve cumulative inheritance`(parentEventTime: Int, bounded: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 17)
        func metadata(_ id: String, parent: String?, time: Int) -> [String: Any] {
            var payload: [String: Any] = [
                "id": id, "source": "vscode", "thread_source": "user",
                "timestamp": env.isoString(for: day.addingTimeInterval(Double(time))),
            ]
            payload["forked_from_id"] = parent
            return ["type": "session_meta", "payload": payload]
        }
        func tokens(_ input: Int, last: Int, time: Int) -> [String: Any] {
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: day.addingTimeInterval(Double(time))),
                "payload": ["type": "token_count", "info": [
                    "model": "gpt-5.4",
                    "total_token_usage": ["input_tokens": input, "output_tokens": 0],
                    "last_token_usage": ["input_tokens": last, "output_tokens": 0],
                ]],
            ]
        }
        let rootFile = try env.writeCodexSessionFile(day: day, filename: "root.jsonl", contents: env.jsonl([
            metadata("root", parent: nil, time: 0), tokens(1000, last: 1000, time: 1),
        ]))
        var parent = [metadata("parent", parent: "root", time: 2)]
        if parentEventTime > 0 { parent.append(tokens(1040, last: 40, time: parentEventTime)) }
        let parentFile = try env.writeCodexSessionFile(
            day: day, filename: "parent.jsonl", contents: env.jsonl(parent))
        let inherited = parentEventTime == 3 ? 1040 : 1000
        _ = try env.writeCodexSessionFile(day: day, filename: "child.jsonl", contents: env.jsonl([
            metadata("child", parent: "parent", time: 4),
            tokens(inherited, last: parentEventTime == 3 ? 40 : 1000, time: 5),
            tokens(inherited + 20, last: 20, time: 6),
            tokens(inherited + 20, last: 20, time: 7),
        ]))
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        if bounded { options.maxCodexScanBytesPerRefresh = 512 }
        var clock = day
        for pass in 0..<4 {
            if pass == 2 {
                var legacy = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
                for path in legacy.files.keys {
                    legacy.files[path]?.codexParserRevision = 4
                }
                CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: legacy)
            }
            options.forceRescan = pass == 3
            let report = try self.completedScan(env: env, day: day, options: options, clock: &clock)
            let cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
            let child = try #require(cache.files.values.first { $0.sessionId == "child" })
            #expect(child.codexRows?.map(\.input) == [20])
            let expected = 1020 + (parentEventTime > 0 ? 40 : 0)
            #expect(report.data.reduce(0) { $0 + ($1.totalTokens ?? 0) } == expected)
        }
        // The unbounded resolver shares the scanner, including forks with no token events.
        let resolver = CostUsageScanner.CodexInheritedTotalsResolver(
            fileIndex: .init(files: [rootFile, parentFile], roots: []), checkCancellation: nil)
        let baseline = try resolver.inheritedTotals(
            for: "parent", atOrBefore: env.isoString(for: day.addingTimeInterval(4)))
        guard case let .resolved(totals) = baseline else {
            Issue.record("Expected a resolved direct-fork baseline")
            return
        }
        #expect(totals?.input == inherited)
        if parentEventTime == 0 {
            let previousDependency = resolver.dependencyKeyUsed(for: "parent")
            try env.jsonl([
                metadata("root", parent: nil, time: 0), tokens(1010, last: 1010, time: 1),
            ]).write(to: rootFile, atomically: true, encoding: .utf8)
            #expect(try resolver.currentDependencyKey(for: "parent") != previousDependency)
            resolver.updateCachedUsage(fileURL: rootFile, usage: nil)
            if case let .resolved(updated) = try resolver.inheritedTotals(
                for: "parent", atOrBefore: env.isoString(for: day.addingTimeInterval(4)))
            {
                #expect(updated?.input == 1010)
            } else {
                Issue.record("Changed empty-fork ancestry should resolve again")
            }
            options.forceRescan = false
            _ = try self.completedScan(env: env, day: day, options: options, clock: &clock)
            let child = try #require(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
                .files.values.first { $0.sessionId == "child" })
            #expect(child.codexRows?.map(\.input) == [10])
        }
    }

    @Test
    func `cyclic empty fork ancestry remains unresolved`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 17)
        var files: [URL] = []
        for (id, parent) in [("a", "b"), ("b", "a")] {
            try files.append(env.writeCodexSessionFile(day: day, filename: "\(id).jsonl", contents: env.jsonl([
                ["type": "session_meta", "payload": [
                    "id": id, "forked_from_id": parent, "timestamp": env.isoString(for: day),
                ]],
            ])))
        }
        let resolver = CostUsageScanner.CodexInheritedTotalsResolver(
            fileIndex: .init(files: files, roots: []), checkCancellation: nil)
        if case .resolved = try resolver.inheritedTotals(for: "a", atOrBefore: env.isoString(for: day)) {
            Issue.record("Cyclic ancestry cannot establish a baseline")
        }
    }

    private func completedScan(
        env: CostUsageTestEnvironment,
        day: Date,
        options: CostUsageScanner.Options,
        clock: inout Date) throws -> CostUsageDailyReport
    {
        var options = options
        for _ in 0..<80 {
            clock.addTimeInterval(1)
            let report = CostUsageScanner.loadDailyReport(
                provider: .codex, since: day, until: day, now: clock, options: options)
            options.forceRescan = false
            let cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
            if cache.files.count == 3, cache.codexScanCatchUpPending != true,
               cache.files.values.allSatisfy({
                   $0.codexScanComplete == true && $0.hasCurrentCodexParser && !$0.hasBufferedCodexForkRetryLines
               })
            {
                return report
            }
        }
        throw NSError(domain: "DirectForkBaselineTests", code: 1)
    }
}
