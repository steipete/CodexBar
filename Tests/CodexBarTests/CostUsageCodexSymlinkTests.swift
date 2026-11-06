import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageCodexSymlinkTests {
    @Test
    func `session directory links preserve inventory and accounting without following nested links`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let fm = FileManager.default
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 1)
        let relatives = ["2026/09/01/dated.jsonl", "flat.jsonl", "legacy/nested.jsonl"]
        let contents = try env.jsonl([
            ["type": "turn_context", "timestamp": env.isoString(for: day), "payload": ["model": "gpt-5.4"]],
            [
                "type": "event_msg", "timestamp": env.isoString(for: day),
                "payload": ["type": "token_count", "info": [
                    "model": "gpt-5.4",
                    "last_token_usage": ["input_tokens": 101, "cached_input_tokens": 0, "output_tokens": 10],
                ]],
            ],
        ])
        for root in [env.codexSessionsRoot, env.codexArchivedSessionsRoot] {
            for relative in relatives {
                let file = root.appendingPathComponent(relative)
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents.write(to: file, atomically: true, encoding: .utf8)
            }
        }
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        func scan() -> CostUsageDailyReport {
            CostUsageScanner.loadDailyReport(provider: .codex, since: day, until: day, now: day, options: options)
        }
        let oracle = scan()
        #expect(oracle.data.first?.inputTokens == 606)
        #expect(oracle.data.first?.outputTokens == 60)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let oracleBytes = try encoder.encode(oracle)

        // Different target parents/names catch deriving the archive sibling after resolving sessions.
        let live = env.root.appendingPathComponent("disk-a/live-history")
        let archive = env.root.appendingPathComponent("disk-b/archive-history")
        for (source, target) in [(env.codexSessionsRoot, live), (env.codexArchivedSessionsRoot, archive)] {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: source, to: target)
            try fm.createSymbolicLink(at: source, withDestinationURL: target)
        }
        let outside = env.root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try contents.write(to: outside.appendingPathComponent("sentinel.jsonl"), atomically: true, encoding: .utf8)
        for root in [live, archive] {
            try fm.createSymbolicLink(at: root.appendingPathComponent("nested-link"), withDestinationURL: outside)
        }
        let expected = Set([live, archive].flatMap { root in
            relatives.map { root.appendingPathComponent($0).resolvingSymlinksInPath().path }
        })
        let roots = CostUsageScanner.codexSessionsRoots(options: options)
        let listed = roots.flatMap {
            CostUsageScanner.listCodexSessionFiles(
                root: $0, scanSinceKey: "2026-09-01", scanUntilKey: "2026-09-01", includeRecursive: true)
        }
        #expect(Set(listed.map { $0.resolvingSymlinksInPath().path }) == expected)
        #expect(listed.count == 6)
        options.cacheRoot = env.root.appendingPathComponent("linked-cache")
        let recorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = recorder
        let cold = scan()
        #expect(cold.data.first?.inputTokens == 606)
        #expect(cold.data.first?.outputTokens == 60)
        #expect(recorder.snapshot().codexFileScanAttempts == 6)
        #expect(try encoder.encode(cold) == oracleBytes)
        #expect(try encoder.encode(scan()) == oracleBytes)
        options.forceRescan = true
        #expect(try encoder.encode(scan()) == oracleBytes)

        // Model an old complete inventory that only knew the two dated files.
        options.forceRescan = false
        options.cacheRoot = env.root.appendingPathComponent("upgrade-cache")
        var parked: [(URL, URL)] = []
        for (index, root) in [live, archive].enumerated() {
            for relative in relatives.dropFirst() {
                let source = root.appendingPathComponent(relative)
                let target = outside.appendingPathComponent("parked-\(index)-\(source.lastPathComponent)")
                try fm.moveItem(at: source, to: target)
                parked.append((source, target))
            }
        }
        #expect(scan().data.first?.inputTokens == 202)
        let home = CodexHomeCostStoreScope.key(options: options)
        var oldInventory = CostUsageStoreAccess.read(cacheRoot: options.cacheRoot, home: home)
        oldInventory.roots = Dictionary(uniqueKeysWithValues: roots.map { ($0.standardizedFileURL.path, 0) })
        CostUsageStoreAccess.replace(cacheRoot: options.cacheRoot, home: home, cache: oldInventory)
        for (source, target) in parked {
            try fm.moveItem(at: target, to: source)
        }
        #expect(try encoder.encode(scan()) == oracleBytes)

        // Two selected roots pointing to the same directory must count each physical file once.
        options.forceRescan = true
        try fm.removeItem(at: env.codexArchivedSessionsRoot)
        try fm.createSymbolicLink(at: env.codexArchivedSessionsRoot, withDestinationURL: live)
        let deduplicated = scan()
        #expect(deduplicated.data.first?.inputTokens == 303)
        #expect(deduplicated.data.first?.outputTokens == 30)
    }
}
