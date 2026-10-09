import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageRequestLedgerMigrationTests {
    @Test(arguments: ["379b799bb4b91683", "7ce21041b7a36242", "0d8f9504f8e63d0f", "7ff985e81e281a11"])
    func `tool inspection upgrade retains saved pricing history and checkpoints`(parserHash: String) async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        let file = try env.writeCodexSessionFile(
            day: day,
            filename: "tool-upgrade.jsonl",
            contents: Self.offsetLedgerLines(day: day, env: env, scenario: (ledgerFirst: true, offsetMs: 400)))
        _ = Self.report(day: day, options: Self.options(env: env))
        var cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        var usage = try #require(cache.files[file.path])
        usage.codexRows = usage.codexRows?.map { row in
            var row = row
            row.pricingMode = "priority"
            return row
        }
        let savedRows = try #require(usage.codexRows)
        #expect(!savedRows.isEmpty)
        cache.files[file.path] = usage
        let upgradeRoot = env.root.appendingPathComponent("upgrade-cache")
        let predecessor = CostUsageStore(
            cacheRoot: upgradeRoot,
            schemaVersion: CostUsageStore.combinedSchemaVersion(
                base: CostUsageStore.baseSchemaVersion, parserHash: parserHash),
            parserHash: parserHash)
        #expect(!predecessor.syncSaveCodexCache(
            cache,
            calendar: .current,
            requestedScanWindow: (sinceKey: "2026-09-10", untilKey: "2026-09-10")).catchUpRequired)
        let before = await predecessor.readSnapshot()
        let inode = try #require(FileManager.default.attributesOfItem(
            atPath: predecessor.databaseURL.path)[.systemFileNumber] as? NSNumber)
        // History and saved pricing must survive even when the original log is no longer available.
        try FileManager.default.removeItem(at: file)
        for _ in 0..<2 {
            let current = CostUsageStore(cacheRoot: upgradeRoot)
            #expect(await current.readSnapshot() == before)
            #expect(await current.rebuildCount == 0)
            #expect(await current.configuration()?.userVersion == Int(CostUsageStore.schemaVersion))
            let adopted = current.syncLoadCodexCache(calendar: .current)
            #expect(adopted.files[file.path]?.codexRows == savedRows)
            #expect(adopted.files[file.path]?.codexRequestLedgerState == usage.codexRequestLedgerState)
            #expect(adopted.files[file.path]?.parsedBytes == usage.parsedBytes)
            #expect(adopted.files[file.path]?.codexScanComplete == usage.codexScanComplete)
            #expect(try FileManager.default.attributesOfItem(
                atPath: current.databaseURL.path)[.systemFileNumber] as? NSNumber == inode)
        }
    }

    @Test(arguments: [5, 6, 7, 8], [false, true])
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
        // Older revisions may have only legacy rows; revision 7 retains its typed identities.
        if revision < 7 { usage.codexRequestLedgerState = nil }
        if revision == 7, let state = usage.codexRequestLedgerState {
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
            object["mirroredSnapshots"] = Array((state.mirroredResponses ?? [:]).keys)
            object.removeValue(forKey: "mirroredResponses")
            object.removeValue(forKey: "pendingLedgerResponseID")
            usage.codexRequestLedgerState = try JSONDecoder().decode(
                CostUsageScanner.CodexRequestLedgerState.self,
                from: JSONSerialization.data(withJSONObject: object))
            #expect(usage.codexRequestLedgerState?.sessionID == "execution-session")
            #expect(usage.codexRequestLedgerState?.responseIDs == ["first"])
            #expect(usage.codexRequestLedgerState?.mirroredResponses == nil)
        }
        usage.codexRows = try usage.codexRows?.map { row in
            var row = row
            row.pricingMode = priority ? "priority" : "standard"
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
            if revision < 7 {
                object.removeValue(forKey: "responseID")
                object.removeValue(forKey: "requestMirrorKeys")
            }
            return try JSONDecoder().decode(
                CostUsageScanner.CodexUsageRow.self,
                from: JSONSerialization.data(withJSONObject: object))
        }
        old.files[file.path] = usage
        #expect(!CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: old).catchUpRequired)
        let predecessorHash = switch revision {
        case 5: "4a4c4ef34ce6f037"
        case 6: "c61aebb9cf043a72"
        case 7: "029fe80aa98f27e8"
        default: "ed735dc27ffa70d9"
        }
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

    @Test(arguments: [
        (ledgerFirst: true, offsetMs: 400, bounded: false),
        (ledgerFirst: false, offsetMs: 400, bounded: false),
        (ledgerFirst: true, offsetMs: -350, bounded: false),
        (ledgerFirst: false, offsetMs: -350, bounded: false),
        (ledgerFirst: true, offsetMs: 400, bounded: true),
        (ledgerFirst: false, offsetMs: -350, bounded: true),
    ], [false, true])
    func `legacy upgrade keeps saved pricing when ledger and token count timestamps differ`(
        _ scenario: (ledgerFirst: Bool, offsetMs: Int, bounded: Bool), counterDrift: Bool) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        let file = try env.writeCodexSessionFile(
            day: day,
            filename: "offset-migration.jsonl",
            contents: Self.offsetLedgerLines(
                day: day, env: env, scenario: (scenario.ledgerFirst, scenario.offsetMs), counterDrift: counterDrift))
        var options = Self.options(env: env)
        let canonical = Self.report(day: day, options: options)
        let standardCost = try #require(canonical.summary?.totalCostUSD)

        // Revision 5 saved token_count rows with their own timestamps and no response identity.
        var old = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        var usage = try #require(old.files[file.path])
        usage.codexParserRevision = 5
        usage.codexRequestLedgerState = nil
        usage.codexRows = try usage.codexRows?.filter { $0.responseID != nil }.enumerated().map { index, row in
            var object = try #require(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
            object.removeValue(forKey: "responseID")
            object.removeValue(forKey: "requestMirrorKeys")
            object["timestampUnixMs"] = Int64((day.timeIntervalSince1970 + Double(index + 1) * 10) * 1000)
            // Saved priority evidence cannot be rederived without traces, so it proves the old row's pricing survived.
            object["pricingMode"] = "priority"
            return try JSONDecoder().decode(
                CostUsageScanner.CodexUsageRow.self,
                from: JSONSerialization.data(withJSONObject: object))
        }
        old.files[file.path] = usage
        #expect(!CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: old).catchUpRequired)
        try Self.markPredecessor(cacheRoot: env.cacheRoot, parserHash: "4a4c4ef34ce6f037")
        if scenario.bounded {
            // Each pass reads about one line, so some slices end between a ledger row and its mirror.
            options.maxCodexScanBytesPerRefresh = 256
            options.maxCodexSessionFileBytes = 256
        }

        var migrated: CostUsageFileUsage?
        var observedPartial = false
        let fileSize = try Int64(Data(contentsOf: file).count)
        for _ in 0..<60 {
            _ = Self.report(day: day, options: options)
            migrated = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
                .files[file.path]
            observedPartial = observedPartial || migrated?.codexScanComplete == false
            if migrated?.hasCurrentCodexParser == true, migrated?.codexScanComplete == true,
               migrated?.parsedBytes == fileSize { break }
        }
        #expect(observedPartial == scenario.bounded)
        let rows = try #require(migrated?.codexRows)
        #expect(migrated?.hasCurrentCodexParser == true)
        #expect(rows.compactMap(\.responseID) == ["offset-0", "offset-1", "offset-2"])
        #expect(rows.map(\.unpricedTokens) == [nil, nil, nil])
        #expect(rows.map(\.pricingMode) == ["priority", "priority", "priority"])
        let upgraded = Self.report(day: day, options: options)
        #expect(upgraded.summary?.totalTokens == canonical.summary?.totalTokens)
        #expect(try #require(upgraded.summary?.totalCostUSD) > standardCost)
    }

    @Test
    func `adopting a 0_72_0 store keeps ledger only pricing markers through reopen`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        let file = try env.writeCodexSessionFile(
            day: day,
            filename: "marked-ledger.jsonl",
            contents: Self.offsetLedgerLines(day: day, env: env, scenario: (ledgerFirst: true, offsetMs: 400)))
        var options = Self.options(env: env)
        options.refreshMinIntervalSeconds = 3600
        #expect(Self.report(day: day, options: options).summary?.totalCostUSD != nil)

        // Invalidated source evidence leaves only fully marked ledger rows. Their pricing is unknown, so adoption
        // must not turn them into estimates; a cache rebuild is the explicit way to reprice from the logs.
        var stored = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        var usage = try #require(stored.files[file.path])
        usage.codexRows = usage.codexRows?.map { row in
            var row = row
            row.unpricedTokens = row.input + row.output
            return row
        }
        let markedRows = try #require(usage.codexRows)
        stored.files[file.path] = usage
        #expect(!CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: stored).catchUpRequired)
        try Self.markPredecessor(cacheRoot: env.cacheRoot, parserHash: "ed735dc27ffa70d9")

        for _ in 0..<2 {
            let reopened = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
            #expect(reopened.files[file.path]?.codexRows == markedRows)
            #expect(Self.report(day: day, options: options).summary?.totalCostUSD == nil)
        }
    }

    /// Identical requests in one turn share a saved-pricing key. If one of them was saved as unknown, the key cannot
    /// prove which request its evidence belongs to, so the upgrade must not price either one from it.
    @Test(arguments: [
        (ledgerFirst: true, bounded: false),
        (ledgerFirst: false, bounded: false),
        (ledgerFirst: true, bounded: true),
    ], [5, 8])
    func `legacy upgrade keeps a marker that shares its pricing key with a priced request`(
        _ scenario: (ledgerFirst: Bool, bounded: Bool), revision: Int) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        let file = try env.writeCodexSessionFile(
            day: day,
            filename: "colliding-migration.jsonl",
            contents: Self.offsetLedgerLines(
                day: day,
                env: env,
                scenario: (scenario.ledgerFirst, 400),
                inputs: [50000, 50000],
                spacingSeconds: 0))
        var options = Self.options(env: env)
        _ = Self.report(day: day, options: options)

        var old = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        var usage = try #require(old.files[file.path])
        usage.codexParserRevision = revision
        usage.codexRequestLedgerState = nil
        usage.codexRows = try usage.codexRows?.enumerated().map { index, row in
            var object = try #require(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
            if revision < 8 {
                object.removeValue(forKey: "responseID")
                object.removeValue(forKey: "requestMirrorKeys")
            }
            object["timestampUnixMs"] = Int64(day.timeIntervalSince1970 * 1000)
            object["pricingMode"] = "priority"
            if index == 1 { object["unpricedTokens"] = row.input + row.output }
            return try JSONDecoder().decode(
                CostUsageScanner.CodexUsageRow.self,
                from: JSONSerialization.data(withJSONObject: object))
        }
        let legacyRows = try #require(usage.codexRows)
        #expect(Set(legacyRows.compactMap(CostUsageScanner.CodexSourcePricingKey.init)).count == 1)
        old.files[file.path] = usage
        #expect(!CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: old).catchUpRequired)
        try Self.markPredecessor(
            cacheRoot: env.cacheRoot,
            parserHash: revision < 8 ? "4a4c4ef34ce6f037" : "ed735dc27ffa70d9")
        if scenario.bounded {
            options.maxCodexScanBytesPerRefresh = 256
            options.maxCodexSessionFileBytes = 256
        }

        var migrated: CostUsageFileUsage?
        let fileSize = try Int64(Data(contentsOf: file).count)
        for _ in 0..<60 {
            _ = Self.report(day: day, options: options)
            migrated = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
                .files[file.path]
            if migrated?.codexScanComplete == false {
                #expect(migrated?.codexPendingSourcePricing == [:])
            }
            if migrated?.hasCurrentCodexParser == true, migrated?.codexScanComplete == true,
               migrated?.parsedBytes == fileSize { break }
        }
        let rows = try #require(migrated?.codexRows)
        let markers: [Int?] = rows.map(\.unpricedTokens)
        let fullMarkers: [Int?] = rows.map { $0.input + $0.output }
        #expect(migrated?.hasCurrentCodexParser == true)
        #expect(rows.count == 2)
        #expect(markers == fullMarkers)
        #expect(Self.report(day: day, options: options).summary?.totalCostUSD == nil)
    }

    /// A replayed response links its later token_count to the original ledger row for deduplication. Only the
    /// original's own mirror may supply that row's saved pricing; the replay's legacy row is a different request.
    struct ReplayScenario: Sendable {
        var bounded = false
        var verbatimDuplicate = false
        var originalUnpriced = false
        var turnTracking = false
        var sameCounterReplay = false
    }

    @Test(arguments: [
        ReplayScenario(),
        .init(bounded: true),
        .init(verbatimDuplicate: true),
        .init(originalUnpriced: true),
        .init(bounded: true, originalUnpriced: true),
        .init(originalUnpriced: true, turnTracking: true),
        .init(bounded: true, originalUnpriced: true, turnTracking: true),
        .init(originalUnpriced: true, sameCounterReplay: true),
        .init(bounded: true, originalUnpriced: true, sameCounterReplay: true),
    ])
    func `legacy upgrade takes saved pricing only from the original request mirror`(
        _ scenario: ReplayScenario) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func tokens(_ input: Int, _ output: Int) -> [String: Int] {
            ["input_tokens": input, "cached_input_tokens": 0, "output_tokens": output]
        }
        /// With turnTracking, a resumed session's token_count totals follow the turn, each ledger record shares its
        /// mirror's timestamp, and the replay's mirror total equals the original record's thread total.
        func ledger(at date: Date, total: Int) -> [String: Any] {
            var payload: [String: Any] = [
                "thread_id": "replay-thread", "session_id": "replay-execution", "response_id": "replay-response",
                "turn_id": "replay-turn", "usage": tokens(100_000, 1000),
                "thread_token_usage": tokens(
                    total + (scenario.turnTracking ? 100_000 : 0),
                    (total + (scenario.turnTracking ? 100_000 : 0)) / 100),
            ]
            if scenario.turnTracking { payload["turn_token_usage"] = tokens(total, total / 100) }
            return [
                "type": "token_usage_record",
                "timestamp": formatter.string(from: date.addingTimeInterval(scenario.turnTracking ? 0 : 0.4)),
                "payload": payload,
            ]
        }
        func count(at date: Date, total: Int) -> [String: Any] {
            ["type": "event_msg", "timestamp": formatter.string(from: date), "payload": [
                "type": "token_count", "turn_id": "replay-turn", "info": [
                    "last_token_usage": tokens(100_000, 1000), "total_token_usage": tokens(total, total / 100),
                ],
            ]]
        }
        let original = day.addingTimeInterval(10)
        let replay = day.addingTimeInterval(20)
        var lines: [[String: Any]] = [
            [
                "type": "session_meta",
                "timestamp": formatter.string(from: day),
                "payload": ["id": "replay-thread", "session_id": "replay-execution"],
            ],
            [
                "type": "turn_context",
                "timestamp": formatter.string(from: day),
                "payload": ["model": "gpt-5.4", "turn_id": "replay-turn"],
            ],
            ledger(at: original, total: 100_000),
        ]
        if scenario.sameCounterReplay {
            // The original had no legacy mirror. Only the later replay was saved by the old parser.
            lines += [ledger(at: replay, total: 100_000), count(at: replay, total: 100_000)]
        } else if scenario.verbatimDuplicate {
            lines += [ledger(at: original, total: 100_000), count(at: original, total: 100_000)]
        } else {
            lines += [
                count(at: original, total: 100_000),
                ledger(at: replay, total: 200_000),
                count(at: replay, total: 200_000),
            ]
        }
        let file = try env.writeCodexSessionFile(
            day: day,
            filename: "replay-migration.jsonl",
            contents: env.jsonl(lines))
        var options = Self.options(env: env)
        _ = Self.report(day: day, options: options)

        // Revision 5 saved one legacy row per token_count: the original request with Priority evidence, and the
        // replay's observation with Standard evidence.
        var old = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        var usage = try #require(old.files[file.path])
        usage.codexParserRevision = 5
        usage.codexRequestLedgerState = nil
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let observations = scenario.sameCounterReplay ? [(replay, "standard")]
            : scenario.verbatimDuplicate ? [(original, "priority")] : [(original, "priority"), (replay, "standard")]
        usage.codexRows = observations.enumerated().map { index, observation in
            CostUsageScanner.CodexUsageRow(
                day: dayKey,
                model: "gpt-5.4",
                rawModel: "gpt-5.4",
                turnID: "replay-turn",
                eventIndex: index,
                timestampUnixMs: Int64(observation.0.timeIntervalSince1970 * 1000),
                input: 100_000,
                cached: 0,
                output: 1000,
                unpricedTokens: index == 0 && scenario.originalUnpriced && !scenario.sameCounterReplay ? 101_000 : nil,
                pricingModel: "gpt-5.4",
                pricingMode: observation.1)
        }
        old.files[file.path] = usage
        #expect(!CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: old).catchUpRequired)
        try Self.markPredecessor(cacheRoot: env.cacheRoot, parserHash: "4a4c4ef34ce6f037")
        if scenario.bounded {
            options.maxCodexScanBytesPerRefresh = 256
            options.maxCodexSessionFileBytes = 256
        }

        var migrated: CostUsageFileUsage?
        let fileSize = try Int64(Data(contentsOf: file).count)
        for _ in 0..<60 {
            _ = Self.report(day: day, options: options)
            migrated = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
                .files[file.path]
            if migrated?.hasCurrentCodexParser == true, migrated?.codexScanComplete == true,
               migrated?.parsedBytes == fileSize { break }
        }
        let rows = try #require(migrated?.codexRows)
        let ledgerRow = try #require(rows.first { $0.responseID == "replay-response" })
        #expect(migrated?.hasCurrentCodexParser == true)
        #expect(rows.count == 1)
        #expect(rows.compactMap(\.responseID) == ["replay-response"])
        if scenario.originalUnpriced {
            // The original was saved unknown; the replay's Standard evidence must not price it.
            #expect(ledgerRow.unpricedTokens == 101_000)
        } else {
            #expect(ledgerRow.unpricedTokens == nil)
            #expect(ledgerRow.pricingMode == "priority")
        }
    }

    private static func options(env: CostUsageTestEnvironment) -> CostUsageScanner.Options {
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0
        return options
    }

    private static func report(day: Date, options: CostUsageScanner.Options) -> CostUsageDailyReport {
        CostUsageScanner.loadDailyReport(provider: .codex, since: day, until: day, now: day, options: options)
    }

    private static func markPredecessor(cacheRoot: URL, parserHash: String) throws {
        let version = CostUsageStore.combinedSchemaVersion(
            base: CostUsageStore.baseSchemaVersion,
            parserHash: parserHash)
        let connection = try BaselineSQLiteConnection(url: CostUsageStore(cacheRoot: cacheRoot).databaseURL)
        try connection.execute("UPDATE meta SET value = '\(parserHash)' WHERE key = 'parser_hash'")
        try connection.execute("PRAGMA user_version = \(version)")
    }

    /// Real Codex logs stamp the owned token_usage_record and its token_count mirror a few hundred ms apart.
    private static func offsetLedgerLines(
        day: Date,
        env: CostUsageTestEnvironment,
        scenario: (ledgerFirst: Bool, offsetMs: Int),
        inputs: [Int] = [200_000, 50000, 25000],
        spacingSeconds: Double = 10,
        counterDrift: Bool = false) throws -> String
    {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func tokens(_ input: Int, output: Int) -> [String: Int] {
            ["input_tokens": input, "cached_input_tokens": 0, "output_tokens": output]
        }
        var lines: [[String: Any]] = [
            [
                "type": "session_meta",
                "timestamp": formatter.string(from: day),
                "payload": ["id": "offset-thread", "session_id": "offset-execution"],
            ],
            [
                "type": "turn_context",
                "timestamp": formatter.string(from: day),
                "payload": ["model": "gpt-5.4", "turn_id": "offset-turn"],
            ],
        ]
        var total = 0
        for (index, input) in inputs.enumerated() {
            total += input
            let countedAt = day.addingTimeInterval(Double(index + 1) * spacingSeconds)
            let ledgerAt = countedAt.addingTimeInterval(Double(scenario.offsetMs) / 1000)
            let ledger: [String: Any] = [
                "type": "token_usage_record", "timestamp": formatter.string(from: ledgerAt), "payload": [
                    "thread_id": "offset-thread", "session_id": "offset-execution", "response_id": "offset-\(index)",
                    "turn_id": "offset-turn", "usage": tokens(input, output: 1000),
                    "thread_token_usage": tokens(total, output: 1000 * (index + 1)),
                ],
            ]
            let count: [String: Any] = [
                "type": "event_msg", "timestamp": formatter.string(from: countedAt), "payload": [
                    "type": "token_count", "turn_id": "offset-turn", "info": [
                        "last_token_usage": tokens(input, output: 1000),
                        "total_token_usage": tokens(total + (counterDrift ? 10000 : 0), output: 1000 * (index + 1)),
                    ],
                ],
            ]
            lines += scenario.ledgerFirst ? [ledger, count] : [count, ledger]
        }
        return try env.jsonl(lines)
    }
}
