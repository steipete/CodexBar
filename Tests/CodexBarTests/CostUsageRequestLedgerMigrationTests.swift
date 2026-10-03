import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageRequestLedgerMigrationTests {
    @Test(arguments: [5, 6], [false, true])
    func `bounded ledger upgrades retain prior pricing across reopen and append`(
        revision: Int,
        priority: Bool) async throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        let timestamp = ISO8601DateFormatter().string(from: day)
        func tokens(_ input: Int) -> [String: Int] {
            ["input_tokens": input, "cached_input_tokens": 0, "output_tokens": 0]
        }
        func pair(_ id: String, input: Int, total: Int) -> [[String: Any]] {
            [
                ["type": "token_usage_record", "timestamp": timestamp, "payload": [
                    "thread_id": "migration-thread", "session_id": "execution-session", "response_id": id,
                    "turn_id": "migration-turn", "usage": tokens(input), "thread_token_usage": tokens(total),
                ]],
                ["type": "event_msg", "timestamp": timestamp, "payload": [
                    "type": "token_count", "turn_id": "migration-turn", "info": [
                        "last_token_usage": tokens(input), "total_token_usage": tokens(total),
                    ],
                ]],
            ]
        }
        let header: [[String: Any]] = [
            [
                "type": "session_meta",
                "timestamp": timestamp,
                "payload": ["id": "migration-thread", "session_id": "execution-session"],
            ],
            [
                "type": "turn_context",
                "timestamp": timestamp,
                "payload": ["model": "gpt-5.4", "turn_id": "migration-turn"],
            ],
        ]
        let prefix = try env.jsonl(header + pair("first", input: 200_000, total: 200_000))
        let file = try env.writeCodexSessionFile(day: day, filename: "migration.jsonl", contents: prefix)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0
        func report(_ selected: CostUsageScanner.Options) -> CostUsageDailyReport {
            CostUsageScanner.loadDailyReport(provider: .codex, since: day, until: day, now: day, options: selected)
        }
        _ = report(options)
        var old = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        var usage = try #require(old.files[file.path])
        usage.codexParserRevision = revision
        // Construct the persisted legacy representation: no response identities, priority retained.
        usage.codexRequestLedgerState = nil
        usage.codexRows = try usage.codexRows?.map { row in
            var row = row
            row.pricingMode = priority ? "priority" : "standard"
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
            object.removeValue(forKey: "responseID")
            object.removeValue(forKey: "requestMirrorKeys")
            return try JSONDecoder().decode(
                CostUsageScanner.CodexUsageRow.self,
                from: JSONSerialization.data(withJSONObject: object))
        }
        old.files[file.path] = usage
        #expect(!CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: old).catchUpRequired)
        let predecessorHash = revision == 5 ? "4a4c4ef34ce6f037" : "c61aebb9cf043a72"
        let predecessorVersion = CostUsageStore.combinedSchemaVersion(
            base: CostUsageStore.baseSchemaVersion, parserHash: predecessorHash)
        let adoptedStore = CostUsageStore(cacheRoot: env.cacheRoot)
        let connection = try BaselineSQLiteConnection(url: adoptedStore.databaseURL)
        try connection.execute("UPDATE meta SET value = '\(predecessorHash)' WHERE key = 'parser_hash'")
        try connection.execute("PRAGMA user_version = \(predecessorVersion)")
        let adopted = adoptedStore.syncLoadCodexCache(calendar: .current)
        #expect(adopted.files[file.path]?.codexRows == usage.codexRows)
        #expect(await adoptedStore.rebuildCount == 0)
        #expect(await adoptedStore.configuration()?.userVersion == Int(CostUsageStore.schemaVersion))
        func append(_ lines: [[String: Any]]) throws {
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(env.jsonl(lines).utf8))
            try handle.close()
        }
        try append(pair("second", input: 50000, total: 250_000))
        options.maxCodexScanBytesPerRefresh = 256
        options.maxCodexSessionFileBytes = 256
        var observedPartial = false
        for _ in 0..<40 {
            _ = report(options)
            let reopened = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
            let current = try #require(reopened.files[file.path])
            observedPartial = observedPartial || current.codexScanComplete == false
            if current.codexScanComplete == true, current.hasCurrentCodexParser,
               try current.parsedBytes == Int64(Data(contentsOf: file).count) { break }
        }
        #expect(observedPartial)
        let migrated = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
        let migratedFile = try #require(migrated.files[file.path])
        #expect(migratedFile.codexRows?.compactMap(\.responseID) == ["first", "second"])
        #expect(migratedFile.codexRows?.first?.pricingMode == (priority ? "priority" : "standard"))
        #expect(migratedFile.codexRows?.last?.pricingMode == "standard")
        #expect(migratedFile.codexScanComplete == true)
        try append(pair("third", input: 25000, total: 275_000))
        options.maxCodexScanBytesPerRefresh = 512 * 1024 * 1024
        options.maxCodexSessionFileBytes = 512 * 1024 * 1024
        let appended = report(options)
        #expect(appended.summary?.totalTokens == 275_000)
        let completed = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
        #expect(completed.files[file.path]?.codexRows?.compactMap(\.responseID) == ["first", "second", "third"])
        #expect(completed.files[file.path]?.codexRows?.first?.pricingMode == (priority ? "priority" : "standard"))
        #expect(completed.files[file.path]?.codexRows?.dropFirst().allSatisfy { $0.pricingMode == "standard" } == true)
        var coldOptions = options
        coldOptions.cacheRoot = env.root.appendingPathComponent("cold-cache")
        _ = report(coldOptions)
        var cold = try CostUsageStoreAccess.read(cacheRoot: #require(coldOptions.cacheRoot))
        let prices = try #require(completed.files[file.path]?.codexRows)
        var coldFile = try #require(cold.files[file.path])
        coldFile.codexRows = coldFile.codexRows?.enumerated().map { index, row in
            var row = row
            row.pricingMode = prices[index].pricingMode
            return row
        }
        cold.files[file.path] = coldFile
        #expect(try !CostUsageStoreAccess.replace(cacheRoot: #require(coldOptions.cacheRoot), cache: cold)
            .catchUpRequired)
        let expected = report(coldOptions)
        #expect(expected.data == appended.data)
        #expect(expected.summary == appended.summary)
        #expect(report(options).data == appended.data)
    }
}
