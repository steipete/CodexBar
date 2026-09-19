import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageCodexSourceRecoveryTests {
    @Test(arguments: [false, true], [false, true])
    func `unchanged source resolves ambiguous cached request rows`(longRequest: Bool, suffixFits: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        let inputs = longRequest ? [200_000, 400_000] : [200_000, 200_000, 200_000]
        let file = try env.writeCodexSessionFile(
            day: day,
            filename: "ambiguous-requests.jsonl",
            contents: Self.sourceLines(inputs: inputs, day: day, env: env).joined(separator: "\n") + "\n")
        var options = Self.options(env: env)
        let original = Self.report(day: day, options: options)
        let canonical = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let canonicalRows = try #require(canonical.files[file.path]?.codexRows)
        #expect(canonicalRows.map(\.input) == inputs)
        #expect(canonicalRows.allSatisfy { $0.turnID == "synthetic-shared-turn" })
        #expect(canonicalRows.allSatisfy { $0.timestampUnixMs == Int64(day.timeIntervalSince1970 * 1000) })
        #expect(original.summary?.totalTokens == 600_000)
        #expect(try abs(#require(original.summary?.totalCostUSD) - (longRequest ? 2.5 : 1.5)) < 1e-9)

        try Self.contaminate(file: file, cache: canonical, day: day, env: env, suffixFits: suffixFits)
        let contaminated = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(contaminated.files[file.path]?.days == canonical.files[file.path]?.days)
        #expect(contaminated.files[file.path]?.mtimeUnixMs == canonical.files[file.path]?.mtimeUnixMs)
        #expect(contaminated.files[file.path]?.size == canonical.files[file.path]?.size)
        #expect(contaminated.files[file.path]?.hasCurrentCodexParser == true)
        #expect(contaminated.files[file.path]?.codexRows?.map(\.input)
            == (suffixFits ? [200_000, 200_000, 200_000, 400_000] :
                [200_000, 200_000, 200_000, 400_000, 400_000]))

        var coldOptions = options
        coldOptions.cacheRoot = env.root.appendingPathComponent("cold-cache")
        let cold = Self.report(day: day, options: coldOptions)
        let recorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = recorder
        options.refreshMinIntervalSeconds = 3600
        let repaired = Self.report(day: day, options: options, elapsed: 1)
        #expect(repaired.data == cold.data)
        #expect(repaired.summary == cold.summary)
        #expect(recorder.snapshot().usageRowsProcessed == inputs.count)
        let reopened = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
        #expect(reopened.files[file.path]?.codexRows == canonicalRows)
        #expect(reopened.files[file.path]?.days == canonical.files[file.path]?.days)
        #expect(reopened.codexScanCatchUpPending != true)

        let unchangedRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = unchangedRecorder
        options.refreshMinIntervalSeconds = 0
        let unchanged = Self.report(day: day, options: options, elapsed: 2)
        #expect(unchanged.data == cold.data)
        #expect(unchangedRecorder.snapshot().usageRowsProcessed == 0)
        #expect(unchangedRecorder.snapshot().usageRowsRepriced == 0)
    }

    @Test(arguments: [false, true])
    func `source replay removes orphan model rows including from an empty session`(emptySource: Bool) async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let inputs = emptySource ? [] : [200_000, 200_000, 200_000]
        let file = try env.writeCodexSessionFile(
            day: day,
            filename: "orphan-model-rows.jsonl",
            contents: Self.sourceLines(inputs: inputs, day: day, env: env).joined(separator: "\n") + "\n")
        var options = Self.options(env: env)
        let original = Self.report(day: day, options: options)
        let canonical = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        var usage = try #require(canonical.files[file.path])
        let originalRows = try #require(usage.codexRows)
        let orphanModel = "gpt-5.4-mini"
        let orphan = CostUsageScanner.CodexUsageRow(
            day: dayKey,
            model: orphanModel,
            rawModel: orphanModel,
            turnID: "synthetic-copied-turn",
            eventIndex: originalRows.count,
            timestampUnixMs: Int64(day.timeIntervalSince1970 * 1000),
            input: 100_000,
            cached: 0,
            output: 0,
            pricingModel: orphanModel,
            pricingMode: "standard")
        usage.codexRows = originalRows + [orphan]
        #expect(usage.days[dayKey]?[orphanModel] == nil)
        #expect(CostUsageScanner.codexExcessPricingRowGroups(usage) == [.init(day: dayKey, model: orphanModel)])

        var contaminated = canonical
        contaminated.files[file.path] = usage
        #expect(!CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: contaminated).catchUpRequired)
        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        let persisted = store.syncLoadCodexCache(calendar: .current)
        #expect(persisted.files[file.path]?.hasCurrentCodexParser == true)
        #expect(persisted.files[file.path]?.mtimeUnixMs == usage.mtimeUnixMs)
        #expect(persisted.files[file.path]?.size == usage.size)
        // Normal persistence materializes the absent row group with an authoritative zero token total.
        #expect(persisted.files[file.path]?.days[dayKey]?[orphanModel] == [0, 0, 0])
        #expect(await store.fetchUsageRows(path: file.path).count == inputs.count + 1)
        #expect(await store.fetchFileDayAggregates(path: file.path).reduce(0) { $0 + $1.requestCount }
            == Int64(inputs.count + 1))

        options.refreshMinIntervalSeconds = 3600
        let repaired = Self.report(day: day, options: options, elapsed: 1)
        #expect(repaired.data == original.data)
        #expect(repaired.summary == original.summary)
        if !emptySource {
            #expect(repaired.summary?.totalTokens == 600_000)
            #expect(try abs(#require(repaired.summary?.totalCostUSD) - 1.5) < 1e-9)
        }
        let reopened = CostUsageStore(cacheRoot: env.cacheRoot)
        let recovered = reopened.syncLoadCodexCache(calendar: .current)
        #expect(recovered.files[file.path]?.codexRows == originalRows)
        #expect(recovered.files[file.path]?.days == canonical.files[file.path]?.days)
        #expect(recovered.codexScanCatchUpPending != true)
        #expect(await reopened.fetchUsageRows(path: file.path).count == inputs.count)
        #expect(await reopened.fetchFileDayAggregates(path: file.path).reduce(0) { $0 + $1.requestCount }
            == Int64(inputs.count))
        #expect(await reopened.fetchDayAggregates(sinceDay: dayKey, untilDay: dayKey)
            .reduce(0) { $0 + $1.requestCount } == Int64(inputs.count))
    }

    @Test(arguments: PricingConflict.allCases)
    func `source replay cannot choose between conflicting retained prices`(conflict: PricingConflict) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        let file = try env.writeCodexSessionFile(
            day: day,
            filename: "conflicting-prices.jsonl",
            contents: Self.sourceLines(inputs: [200_000, 400_000], day: day, env: env)
                .joined(separator: "\n") + "\n")
        let options = Self.options(env: env)
        _ = Self.report(day: day, options: options)
        var cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        var usage = try #require(cache.files[file.path])
        var rows = Self.contaminatedRows(day: day)
        // Identical request identity cannot establish which conflicting saved price was observed.
        switch conflict {
        case .mode:
            rows.append(Self.row(input: 200_000, index: 0, day: day, pricingMode: "priority"))
        case .model:
            rows.append(Self.row(input: 200_000, index: 0, day: day, pricingModel: "gpt-5.4-mini"))
        case .monetary:
            rows[0] = Self.row(input: 200_000, index: 0, day: day, knownCostNanos: 1_000_000_000)
            rows.append(Self.row(input: 200_000, index: 0, day: day, knownCostNanos: 2_000_000_000))
        }
        usage.codexRows = rows
        cache.files[file.path] = usage
        #expect(!CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: cache).catchUpRequired)

        let refreshed = Self.report(day: day, options: options, elapsed: 1)
        #expect(refreshed.summary?.totalTokens == 600_000)
        #expect(refreshed.data.first?.costUSD == nil)
        #expect(refreshed.summary?.totalCostUSD == nil)
        let reopened = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
        let cached = CostUsageScanner.buildCodexReportFromCache(
            cache: reopened,
            range: .init(since: day, until: day),
            modelsDevCatalog: ModelsDevCatalog(providers: [:]))
        #expect(cached.summary?.totalTokens == 600_000)
        #expect(cached.summary?.totalCostUSD == nil)
    }

    @Test(arguments: [false, true], [false, true])
    func `bounded source recovery retains unanimous pricing after reopening its store`(
        priority: Bool,
        cutHeader: Bool) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        let inputs = [200_000, 200_000, 200_000]
        let lines = try Self.sourceLines(inputs: inputs, day: day, env: env)
        let file = try env.writeCodexSessionFile(
            day: day,
            filename: "bounded-recovery.jsonl",
            contents: lines.joined(separator: "\n") + "\n")
        var options = Self.options(env: env)
        _ = Self.report(day: day, options: options)
        var canonical = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        if priority {
            var usage = try #require(canonical.files[file.path])
            usage.codexRows = usage.codexRows?.map { row in
                var row = row
                row.pricingMode = "priority"
                return row
            }
            canonical.files[file.path] = usage
            #expect(!CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: canonical).catchUpRequired)
            canonical = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        }
        let expected = Self.cachedReport(cache: canonical, day: day)
        let canonicalRows = try #require(canonical.files[file.path]?.codexRows)
        try Self.contaminate(
            file: file,
            cache: canonical,
            day: day,
            env: env,
            pricingMode: priority ? "priority" : "standard")

        let budget = cutHeader ? Int64(lines[0].utf8.count / 2) :
            Int64((lines.prefix(4).joined(separator: "\n") + "\n").utf8.count)
        options.maxCodexScanBytesPerRefresh = budget
        options.maxCodexSessionFileBytes = budget
        _ = Self.report(day: day, options: options, elapsed: 1)
        var initialPass = 1
        var partial = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
        // A tiny budget may first be consumed by bounded session discovery.
        while partial.files[file.path]?.codexScanComplete != false, initialPass < 5 {
            initialPass += 1
            _ = Self.report(day: day, options: options, elapsed: Double(initialPass))
            partial = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
        }
        let partialFile = try #require(partial.files[file.path])
        let initialOffset = try #require(partialFile.parsedBytes)
        #expect(partialFile.codexScanComplete == false)
        #expect(initialOffset > 0)
        #expect(initialOffset < partialFile.size)
        if cutHeader { #expect(initialOffset < lines[0].utf8.count) }
        #expect(partialFile.codexRows?.contains { $0.input == 400_000 } == false)
        #expect(partialFile.codexRows?.allSatisfy { $0.pricingMode == (priority ? "priority" : "standard") } == true)

        var completed = false
        for pass in (initialPass + 1)..<(initialPass + 60) {
            _ = Self.report(day: day, options: options, elapsed: Double(pass))
            let reopened = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
            if reopened.codexScanCatchUpPending != true {
                completed = true
                break
            }
        }
        #expect(completed)
        let final = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
        let finalFile = try #require(final.files[file.path])
        #expect(finalFile.codexScanComplete == true)
        #expect(try #require(finalFile.parsedBytes) > initialOffset)
        #expect(finalFile.codexRows == canonicalRows)
        #expect(finalFile.codexPendingPricing == nil)
        #expect(finalFile.codexPendingSourcePricing == nil)
        let report = Self.cachedReport(cache: final, day: day)
        #expect(report.data == expected.data)
        #expect(report.summary == expected.summary)
        if priority {
            #expect(report.data.first?.modelBreakdowns?.first?.priorityTokens == 600_000)
            #expect(try abs(#require(report.summary?.totalCostUSD) - 3) < 1e-9)
        }
    }

    @Test
    func `append after bounded recovery is consumed once beyond the frozen target`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        let lines = try Self.sourceLines(inputs: [200_000, 200_000, 200_000], day: day, env: env)
        let contents = lines.joined(separator: "\n") + "\n"
        let originalSize = Int64(contents.utf8.count)
        let file = try env.writeCodexSessionFile(day: day, filename: "growing-recovery.jsonl", contents: contents)
        var options = Self.options(env: env)
        _ = Self.report(day: day, options: options)
        let canonical = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        try Self.contaminate(file: file, cache: canonical, day: day, env: env)

        let budget = Int64((lines.prefix(4).joined(separator: "\n") + "\n").utf8.count)
        options.maxCodexScanBytesPerRefresh = budget
        options.maxCodexSessionFileBytes = budget
        _ = Self.report(day: day, options: options, elapsed: 1)
        let partial = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
        #expect(partial.files[file.path]?.codexScanComplete == false)
        #expect(partial.files[file.path]?.codexScanTargetSize == originalSize)

        let timestamp = env.isoString(for: day.addingTimeInterval(3))
        let suffix = try env.jsonl([
            [
                "type": "event_msg", "timestamp": timestamp,
                "payload": ["type": "task_started", "turn_id": "synthetic-appended-turn"],
            ],
            [
                "type": "event_msg", "timestamp": timestamp,
                "payload": [
                    "type": "token_count",
                    "info": ["last_token_usage": [
                        "input_tokens": 50000, "cached_input_tokens": 0, "output_tokens": 0,
                    ]],
                ],
            ],
        ]) + "\n"
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(suffix.utf8))
        try handle.close()

        var coldOptions = Self.options(env: env)
        coldOptions.cacheRoot = env.root.appendingPathComponent("growing-cold-cache")
        let cold = Self.report(day: day, options: coldOptions, elapsed: 4)
        #expect(cold.summary?.totalTokens == 650_000)
        #expect(try abs(#require(cold.summary?.totalCostUSD) - 1.625) < 1e-9)
        var sawCompletedOriginalTarget = false
        var completed = false
        for pass in 2..<30 {
            _ = Self.report(day: day, options: options, elapsed: Double(pass))
            let reopened = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
            let usage = try #require(reopened.files[file.path])
            if usage.parsedBytes == originalSize {
                sawCompletedOriginalTarget = true
                #expect(usage.codexScanTargetSize == originalSize)
                #expect(usage.codexRows?.map(\.input) == [200_000, 200_000, 200_000])
                #expect(usage.codexPendingSourcePricing == nil)
            }
            if reopened.codexScanCatchUpPending != true, usage.parsedBytes == usage.size {
                completed = true
                break
            }
        }
        #expect(sawCompletedOriginalTarget)
        #expect(completed)
        let final = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
        let rows = try #require(final.files[file.path]?.codexRows)
        #expect(rows.map(\.input) == [200_000, 200_000, 200_000, 50000])
        let appended = try #require(rows.last)
        #expect(appended.turnID == "synthetic-appended-turn")
        #expect(appended.unpricedTokens == nil)
        #expect(appended.pricingMode == "standard")
        #expect(Self.cachedReport(cache: final, day: day).data == cold.data)
        let recorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = recorder
        let unchanged = Self.report(day: day, options: options, elapsed: 30)
        #expect(unchanged.data == cold.data)
        #expect(recorder.snapshot().usageRowsProcessed == 0)
    }

    @Test
    func `fork source recovery preserves the parent baseline without inherited inflation`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        let parentTimestamp = env.isoString(for: day)
        let parentUsageTimestamp = env.isoString(for: day.addingTimeInterval(1))
        let forkTimestamp = env.isoString(for: day.addingTimeInterval(2))
        let childDay = day.addingTimeInterval(3)
        let childTimestamp = env.isoString(for: childDay)
        func totalTokens(_ input: Int, timestamp: String) -> [String: Any] {
            [
                "type": "event_msg", "timestamp": timestamp,
                "payload": [
                    "type": "token_count",
                    "info": ["total_token_usage": [
                        "input_tokens": input, "cached_input_tokens": 0, "output_tokens": 0,
                    ]],
                ],
            ]
        }
        let parent = try env.writeCodexSessionFile(
            day: day,
            filename: "a-recovery-parent.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta", "timestamp": parentTimestamp,
                    "payload": ["id": "synthetic-parent-session", "timestamp": parentTimestamp],
                ],
                ["type": "turn_context", "timestamp": parentTimestamp, "payload": ["model": "gpt-5.4"]],
                [
                    "type": "event_msg", "timestamp": parentUsageTimestamp,
                    "payload": ["type": "task_started", "turn_id": "synthetic-parent-turn"],
                ],
                totalTokens(100_000, timestamp: parentUsageTimestamp),
            ]))
        let child = try env.writeCodexSessionFile(
            day: day,
            filename: "z-recovery-child.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta", "timestamp": forkTimestamp,
                    "payload": [
                        "id": "synthetic-child-session", "forked_from_id": "synthetic-parent-session",
                        "timestamp": forkTimestamp,
                    ],
                ],
                ["type": "turn_context", "timestamp": forkTimestamp, "payload": ["model": "gpt-5.4"]],
                [
                    "type": "event_msg", "timestamp": childTimestamp,
                    "payload": ["type": "task_started", "turn_id": "synthetic-shared-turn"],
                ],
                totalTokens(300_000, timestamp: childTimestamp),
                totalTokens(500_000, timestamp: childTimestamp),
                totalTokens(700_000, timestamp: childTimestamp),
            ]))
        var options = Self.options(env: env)
        options.preferNewestCodexSessionsFirst = false
        let original = Self.report(day: day, options: options)
        #expect(original.summary?.totalTokens == 700_000)
        #expect(try abs(#require(original.summary?.totalCostUSD) - 1.75) < 1e-9)
        let canonical = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let originalChild = try #require(canonical.files[child.path])
        #expect(originalChild.forkedFromId == "synthetic-parent-session")
        #expect(originalChild.codexRows?.map(\.input) == [200_000, 200_000, 200_000])
        try Self.contaminate(file: child, cache: canonical, day: childDay, env: env)

        var coldOptions = options
        coldOptions.cacheRoot = env.root.appendingPathComponent("fork-cold-cache")
        let cold = Self.report(day: day, options: coldOptions)
        let recorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = recorder
        options.refreshMinIntervalSeconds = 3600
        let repaired = Self.report(day: day, options: options, elapsed: 1)
        #expect(repaired.data == cold.data)
        #expect(repaired.summary == cold.summary)
        #expect(recorder.snapshot().usageRowsProcessed == 3)
        let reopened = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
        #expect(reopened.files[parent.path] == canonical.files[parent.path])
        #expect(reopened.files[child.path]?.codexRows == originalChild.codexRows)
        #expect(reopened.files[child.path]?.days == originalChild.days)
        #expect(reopened.files[child.path]?.forkBaselineDependencyKey == originalChild.forkBaselineDependencyKey)
        #expect(reopened.codexScanCatchUpPending != true)
    }

    @Test
    func `unavailable source retains unknown history without bypassing debounce`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        let file = try env.writeCodexSessionFile(
            day: day,
            filename: "unavailable-source.jsonl",
            contents: Self.sourceLines(inputs: [200_000, 200_000, 200_000], day: day, env: env)
                .joined(separator: "\n") + "\n")
        var options = Self.options(env: env)
        _ = Self.report(day: day, options: options)
        let canonical = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        try Self.contaminate(file: file, cache: canonical, day: day, env: env)
        let before = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        try FileManager.default.removeItem(at: file)

        let recorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = recorder
        options.refreshMinIntervalSeconds = 3600
        let refreshed = Self.report(day: day, options: options, elapsed: 1)
        #expect(refreshed.summary?.totalTokens == 600_000)
        #expect(refreshed.summary?.totalCostUSD == nil)
        #expect(recorder.snapshot().codexFileScanAttempts == 0)
        #expect(recorder.snapshot().usageRowsProcessed == 0)
        let after = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
        #expect(after.files[file.path]?.codexRows == before.files[file.path]?.codexRows)
        #expect(after.files[file.path]?.days == before.files[file.path]?.days)
        #expect(after.lastScanUnixMs == before.lastScanUnixMs)
        #expect(after.codexScanCatchUpPending != true)
    }

    @Test
    func `recovering an available source preserves unrelated unavailable history`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        let available = try env.writeCodexSessionFile(
            day: day,
            filename: "available-source.jsonl",
            contents: Self.sourceLines(inputs: [200_000, 200_000, 200_000], day: day, env: env)
                .joined(separator: "\n") + "\n")
        let unavailable = try env.writeCodexSessionFile(
            day: day,
            filename: "unavailable-history.jsonl",
            contents: Self.sourceLines(
                inputs: [200_000, 400_000],
                day: day,
                env: env,
                sessionID: "synthetic-unavailable-session").joined(separator: "\n") + "\n")
        var options = Self.options(env: env)
        let original = Self.report(day: day, options: options)
        #expect(original.summary?.totalTokens == 1_200_000)
        let canonical = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        var contaminated = canonical
        contaminated.files[available.path]?.codexRows = Self.contaminatedRows(day: day)
        contaminated.files[unavailable.path]?.codexRows = Self.contaminatedRows(day: day)
        #expect(!CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: contaminated).catchUpRequired)
        try FileManager.default.removeItem(at: unavailable)

        let recorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = recorder
        options.refreshMinIntervalSeconds = 3600
        let refreshed = Self.report(day: day, options: options, elapsed: 1)
        #expect(refreshed.summary?.totalTokens == 1_200_000)
        #expect(refreshed.summary?.totalCostUSD == nil)
        #expect(recorder.snapshot().usageRowsProcessed == 3)
        let reopened = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
        #expect(reopened.files[available.path]?.codexRows == canonical.files[available.path]?.codexRows)
        #expect(reopened.files[unavailable.path]?.codexRows == contaminated.files[unavailable.path]?.codexRows)
        #expect(reopened.files[unavailable.path]?.days == canonical.files[unavailable.path]?.days)
        #expect(Self.cachedReport(cache: reopened, day: day).summary?.totalTokens == 1_200_000)
    }

    @Test
    func `source requests without retained pricing stay unpriced after recovery`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        let file = try env.writeCodexSessionFile(
            day: day,
            filename: "missing-request-prices.jsonl",
            contents: Self.sourceLines(inputs: [100_000, 200_000, 300_000], day: day, env: env)
                .joined(separator: "\n") + "\n")
        var options = Self.options(env: env)
        _ = Self.report(day: day, options: options)
        let canonical = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        try Self.contaminate(file: file, cache: canonical, day: day, env: env)
        options.refreshMinIntervalSeconds = 3600
        let refreshed = Self.report(day: day, options: options, elapsed: 1)
        #expect(refreshed.summary?.totalTokens == 600_000)
        #expect(refreshed.summary?.totalCostUSD == nil)
        let slice = try #require(refreshed.quotaSlices.first)
        #expect(slice.totalTokens == 600_000)
        #expect(slice.tokensAreComplete)
        #expect((slice.costUSD ?? 0) > 0)
        #expect(!slice.costIsComplete)
        let reopened = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
        let rows = try #require(reopened.files[file.path]?.codexRows)
        #expect(rows.map(\.input) == [100_000, 200_000, 300_000])
        #expect(rows.map(\.unpricedTokens) == [100_000, nil, 300_000])
        #expect(reopened.files[file.path]?.days == canonical.files[file.path]?.days)
        #expect(reopened.codexScanCatchUpPending != true)
        let reopenedReport = Self.cachedReport(cache: reopened, day: day)
        #expect(reopenedReport.summary?.totalCostUSD == nil)
        #expect(reopenedReport.quotaSlices == refreshed.quotaSlices)

        let recorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = recorder
        options.refreshMinIntervalSeconds = 0
        let repeated = Self.report(day: day, options: options, elapsed: 2)
        #expect(repeated.summary?.totalTokens == 600_000)
        #expect(repeated.summary?.totalCostUSD == nil)
        #expect(repeated.quotaSlices == refreshed.quotaSlices)
        #expect(recorder.snapshot().usageRowsProcessed == 0)
        #expect(recorder.snapshot().usageRowsRepriced == 0)
        #expect(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).files[file.path]?.codexRows == rows)
    }

    @Test
    func `distinct canonical equal content requests retain different authoritative prices`() throws {
        let day = Date(timeIntervalSince1970: 1_788_955_200)
        let rows = [
            Self.row(input: 200_000, index: 0, day: day, knownCostNanos: 1_000_000_000),
            Self.row(input: 200_000, index: 1, day: day, knownCostNanos: 2_000_000_000),
        ]
        let usage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 1,
            size: 1,
            days: [CostUsageScanner.CostUsageDayRange.dayKey(from: day): ["gpt-5.4": [400_000, 0, 0]]],
            parsedBytes: 1,
            codexRows: rows,
            codexScanComplete: true)
        let reconciled = CostUsageScanner.codexCanonicalPricingRows(usage)
        #expect(reconciled.rows == rows)
        #expect(reconciled.unresolvedGroups.isEmpty)
        var cache = CostUsageCache()
        cache.files = ["/synthetic-canonical-requests.jsonl": usage]
        cache.days = usage.days
        let report = Self.cachedReport(cache: cache, day: day)
        #expect(report.summary?.totalTokens == 400_000)
        #expect(try abs(#require(report.summary?.totalCostUSD) - 3) < 1e-9)
    }

    @Test(arguments: [false, true])
    func `unresolved rows cannot replace recorded prices with a flat aggregate`(authoritativeZero: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let model = "gpt-5.4-mini"
        let rows = [500, 1000].enumerated().map { index, input in
            CostUsageScanner.CodexUsageRow(
                day: dayKey,
                model: model,
                turnID: "synthetic-turn",
                eventIndex: index,
                timestampUnixMs: Int64(day.timeIntervalSince1970 * 1000),
                input: input,
                cached: 0,
                output: 0,
                knownCostNanos: authoritativeZero ? 0 : nil,
                pricingModel: authoritativeZero ? model : "gpt-5.4",
                pricingMode: "standard")
        }
        var usage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 1,
            size: 1,
            days: [dayKey: [model: [1000, 0, 0]]],
            parsedBytes: 1,
            codexRows: rows,
            codexScanComplete: true)
        var cache = CostUsageCache()
        cache.files["/synthetic-price-evidence.jsonl"] = usage
        cache.days = usage.days
        let unknown = Self.cachedReport(cache: cache, day: day)
        #expect(unknown.summary?.totalTokens == 1000)
        #expect(unknown.summary?.totalCostUSD == nil)

        usage.days = [dayKey: [model: [1500, 0, 0]]]
        cache.files["/synthetic-price-evidence.jsonl"] = usage
        cache.days = usage.days
        let exact = Self.cachedReport(cache: cache, day: day)
        #expect(try abs(#require(exact.summary?.totalCostUSD) - (authoritativeZero ? 0 : 0.00375)) < 1e-12)
    }

    enum PricingConflict: String, CaseIterable, Sendable {
        case mode
        case model
        case monetary
    }

    private static func options(env: CostUsageTestEnvironment) -> CostUsageScanner.Options {
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0
        return options
    }

    private static func report(
        day: Date,
        options: CostUsageScanner.Options,
        elapsed: Double = 0) -> CostUsageDailyReport
    {
        CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(elapsed),
            options: options)
    }

    private static func contaminate(
        file: URL,
        cache: CostUsageCache,
        day: Date,
        env: CostUsageTestEnvironment,
        pricingMode: String = "standard",
        suffixFits: Bool = false) throws
    {
        var cache = cache
        var usage = try #require(cache.files[file.path])
        usage.codexRows = self.contaminatedRows(day: day, pricingMode: pricingMode)
        if suffixFits { usage.codexRows?.removeLast() }
        cache.files[file.path] = usage
        #expect(!CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: cache).catchUpRequired)
    }

    private static func cachedReport(cache: CostUsageCache, day: Date) -> CostUsageDailyReport {
        CostUsageScanner.buildCodexReportFromCache(
            cache: cache,
            range: .init(since: day, until: day),
            modelsDevCatalog: ModelsDevCatalog(providers: [:]))
    }

    private static func contaminatedRows(
        day: Date,
        pricingMode: String = "standard") -> [CostUsageScanner.CodexUsageRow]
    {
        [200_000, 200_000, 200_000, 400_000, 400_000].enumerated().map { index, input in
            self.row(input: input, index: index, day: day, pricingMode: pricingMode)
        }
    }

    private static func row(
        input: Int,
        index: Int,
        day: Date,
        pricingModel: String = "gpt-5.4",
        pricingMode: String = "standard",
        knownCostNanos: Int64? = nil) -> CostUsageScanner.CodexUsageRow
    {
        CostUsageScanner.CodexUsageRow(
            day: CostUsageScanner.CostUsageDayRange.dayKey(from: day),
            model: "gpt-5.4",
            rawModel: "gpt-5.4",
            turnID: "synthetic-shared-turn",
            eventIndex: index,
            timestampUnixMs: Int64(day.timeIntervalSince1970 * 1000),
            input: input,
            cached: 0,
            output: 0,
            knownCostNanos: knownCostNanos,
            pricingModel: pricingModel,
            pricingMode: pricingMode)
    }

    private static func sourceLines(
        inputs: [Int],
        day: Date,
        env: CostUsageTestEnvironment,
        sessionID: String = "synthetic-recovery-session") throws -> [String]
    {
        let timestamp = env.isoString(for: day)
        var records: [[String: Any]] = [
            ["type": "session_meta", "timestamp": timestamp, "payload": ["id": sessionID]],
            ["type": "turn_context", "timestamp": timestamp, "payload": ["model": "gpt-5.4"]],
            [
                "type": "event_msg", "timestamp": timestamp,
                "payload": ["type": "task_started", "turn_id": "synthetic-shared-turn"],
            ],
        ]
        for input in inputs {
            records.append([
                "type": "event_msg", "timestamp": timestamp,
                "payload": [
                    "type": "token_count",
                    "info": ["last_token_usage": [
                        "input_tokens": input, "cached_input_tokens": 0, "output_tokens": 0,
                    ]],
                ],
            ])
        }
        return try records.map { try env.jsonl([$0]) }
    }
}

extension CostUsageCodexSourceRecoveryTests {
    @Test
    func `buffered subagent growth prices only original requests from retained evidence`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        let lines = try Self.subagentRecoverySourceLines(day: day, env: env)
        let contents = lines.joined(separator: "\n") + "\n"
        let originalSize = Int64(contents.utf8.count)
        let file = try env.writeCodexSessionFile(day: day, filename: "growing-subagent.jsonl", contents: contents)
        var options = Self.options(env: env)
        let original = Self.report(day: day, options: options)
        #expect(original.summary?.totalTokens == 600_000)
        var contaminated = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(contaminated.files[file.path]?.codexRows?.map(\.input) == [200_000, 200_000, 200_000])
        contaminated.files[file.path]?.codexRows = Self.contaminatedRows(day: day, pricingMode: "priority").map { row in
            var row = row
            row.pricingModel = "gpt-5.5"
            return row
        }
        #expect(!CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: contaminated).catchUpRequired)

        let budget: Int64 = 512
        options.maxCodexScanBytesPerRefresh = budget
        options.maxCodexSessionFileBytes = budget
        _ = Self.report(day: day, options: options, elapsed: 1)
        let interrupted = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
        let partial = try #require(interrupted.files[file.path])
        #expect(partial.codexScanComplete == false)
        #expect(partial.codexScanTargetSize == originalSize)
        #expect(partial.hasBufferedCodexSubagentLines)
        #expect(try #require(partial.codexPendingSourcePricing).isEmpty == false)

        let suffix = try (3..<9).map { try Self.subagentRecoveryTokenLine(index: $0, day: day, env: env) }
            .joined(separator: "\n") + "\n"
        #expect(suffix.utf8.count > Int(budget * 2))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(suffix.utf8))
        try handle.close()
        var coldOptions = Self.options(env: env)
        coldOptions.cacheRoot = env.root.appendingPathComponent("subagent-cold-cache")
        let cold = Self.report(day: day, options: coldOptions, elapsed: 2)
        #expect(cold.summary?.totalTokens == 1_800_000)
        let coldCache = CostUsageStoreAccess.read(cacheRoot: coldOptions.cacheRoot)

        var sawBufferedTail = false
        var completed = false
        for pass in 2..<50 {
            _ = Self.report(day: day, options: options, elapsed: Double(pass))
            let reopened = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
            let usage = try #require(reopened.files[file.path])
            if usage.hasBufferedCodexSubagentLines,
               (usage.parsedBytes ?? 0) >= originalSize,
               (usage.parsedBytes ?? 0) < usage.size
            {
                sawBufferedTail = true
                #expect(usage.codexPendingSourcePricing != nil)
            }
            if reopened.codexScanCatchUpPending != true,
               usage.codexScanComplete == true,
               !usage.hasBufferedCodexForkRetryLines
            {
                completed = true
                break
            }
        }
        #expect(sawBufferedTail)
        #expect(completed)
        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        let final = store.syncLoadCodexCache(calendar: .current)
        let usage = try #require(final.files[file.path])
        let rows = try #require(usage.codexRows)
        #expect(rows.count == 9)
        #expect(rows.map(\.input) == coldCache.files[file.path]?.codexRows?.map(\.input))
        #expect(usage.days == coldCache.files[file.path]?.days)
        #expect(Set(rows.compactMap(CostUsageScanner.CodexSourcePricingKey.init)).count == 1)
        #expect(rows.prefix(3).allSatisfy { $0.pricingMode == "priority" && $0.pricingModel == "gpt-5.5" })
        #expect(rows.suffix(6).allSatisfy { $0.pricingMode == "standard" && $0.pricingModel == "gpt-5.4" })
        #expect(rows.allSatisfy { $0.unpricedTokens == nil })
        #expect(usage.codexPendingSourcePricing == nil)
        #expect(usage.codexPendingSourcePricingAnchor == nil)
        #expect(await store.fetchUsageRows(path: file.path).count == 9)
        #expect(await store.fetchFileDayAggregates(path: file.path).reduce(0) { $0 + $1.requestCount } == 9)
        let report = Self.cachedReport(cache: final, day: day)
        #expect(report.summary?.totalTokens == cold.summary?.totalTokens)
        let historicalCost = try #require(CostUsagePricing.codexPriorityCostUSD(
            model: "gpt-5.5", inputTokens: 200_000, cachedInputTokens: 0, outputTokens: 0)) * 3
        let appendedCost = try #require(CostUsagePricing.codexCostUSD(
            model: "gpt-5.4", inputTokens: 200_000, cachedInputTokens: 0, outputTokens: 0)) * 6
        #expect(try abs(#require(report.summary?.totalCostUSD) - historicalCost - appendedCost) < 1e-9)
        let recorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = recorder
        let unchanged = Self.report(day: day, options: options, elapsed: 50)
        #expect(unchanged.data == report.data)
        #expect(recorder.snapshot().usageRowsProcessed == 0)
    }

    @Test
    func `same size rewrite outside a large source anchor discards retained prices`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        var lines = try Self.sourceLines(inputs: [200_000, 200_000, 200_000], day: day, env: env)
        lines.insert(#"{"type":"synthetic_note","payload":{"marker":"before"}}"#, at: 1)
        let padding = String(repeating: "x", count: 80 * 1024)
        lines.append(#"{"type":"synthetic_note","payload":{"padding":"\#(padding)"}}"#)
        let contents = lines.joined(separator: "\n") + "\n"
        let originalData = Data(contents.utf8)
        #expect(originalData.count > 64 * 1024)
        let markerOffset = try #require(originalData.range(of: Data("before".utf8))?.lowerBound)
        let file = try env.writeCodexSessionFile(day: day, filename: "large-recovery.jsonl", contents: contents)
        let options = Self.options(env: env)
        _ = Self.report(day: day, options: options)
        let canonical = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        try Self.contaminate(file: file, cache: canonical, day: day, env: env, pricingMode: "priority")
        let selected = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let cached = try #require(selected.files[file.path])
        let anchor = try #require(cached.codexTokenIndexAnchor)
        #expect(anchor.windowStart > markerOffset + "before".utf8.count)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let before = CostUsageScanner.codexSourcePricingForScan(
            cached: cached,
            metadata: CostUsageScanner.codexFileMetadata(fileURL: file),
            range: range,
            recoveringSourceRows: true)
        #expect(try #require(before).isEmpty == false)

        // Rewrite only ignored metadata before the sampled window, leaving all request identities unchanged.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: UInt64(markerOffset))
        try handle.write(contentsOf: Data("after!".utf8))
        try handle.close()
        let modified = Date(timeIntervalSince1970: Double(cached.mtimeUnixMs) / 1000 + 5)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        let metadata = CostUsageScanner.codexFileMetadata(fileURL: file)
        #expect(metadata.fileId == cached.codexScanFileId)
        #expect(metadata.size == cached.size)
        #expect(metadata.mtimeUnixMs != cached.mtimeUnixMs)
        #expect(CostUsageScanner.codexTokenIndexAnchorMatches(anchor, fileURL: file, metadata: metadata))
        let after = CostUsageScanner.codexSourcePricingForScan(
            cached: cached,
            metadata: metadata,
            range: range,
            recoveringSourceRows: true)
        #expect(try #require(after).isEmpty)
    }

    @Test
    func `rewriting an unparsed suffix invalidates retained recovery pricing`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        var lines = try Self.sourceLines(inputs: [200_000, 200_000, 200_000], day: day, env: env)
        let prefixBytes = (lines.prefix(4).joined(separator: "\n") + "\n").utf8.count
        let padding = String(repeating: "x", count: 100)
        lines.insert(
            #"{"type":"synthetic_note","payload":{"padding":"\#(padding)","marker":"before"}}"#,
            at: 4)
        let contents = lines.joined(separator: "\n") + "\n"
        let originalData = Data(contents.utf8)
        #expect(originalData.count < 64 * 1024)
        let markerOffset = try #require(originalData.range(of: Data("before".utf8))?.lowerBound)
        let file = try env.writeCodexSessionFile(day: day, filename: "rewritten-tail.jsonl", contents: contents)
        var options = Self.options(env: env)
        _ = Self.report(day: day, options: options)
        let canonical = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let originalAnchor = try #require(canonical.files[file.path]?.codexTokenIndexAnchor)
        #expect(originalAnchor.windowStart == 0)
        try Self.contaminate(file: file, cache: canonical, day: day, env: env, pricingMode: "priority")

        let checkpointBoundary = Int64(prefixBytes + 16)
        var checkpoint: CostUsageFileUsage?
        var setupPass = 0
        var consumedPrefix: Int64 = 0
        for pass in 1..<10 {
            // Discovery can consume a pass's budget; each retry stops before the suffix marker.
            let remaining = checkpointBoundary - consumedPrefix
            try #require(remaining > 0)
            options.maxCodexScanBytesPerRefresh = remaining
            options.maxCodexSessionFileBytes = remaining
            _ = Self.report(day: day, options: options, elapsed: Double(pass))
            let interrupted = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
            let usage = try #require(interrupted.files[file.path])
            guard usage.codexScanComplete == false else { continue }
            consumedPrefix = try #require(usage.parsedBytes)
            try #require(consumedPrefix < markerOffset)
            if usage.codexRows?.count == 1 {
                checkpoint = usage
                setupPass = pass
                break
            }
        }
        let previous = try #require(checkpoint)
        #expect(previous.codexScanComplete == false)
        #expect(previous.codexRows?.count == 1)
        #expect(previous.codexRows?.first?.pricingMode == "priority")
        let parsedBytes = try #require(previous.parsedBytes)
        #expect(parsedBytes < markerOffset)
        let parsedAnchor = try #require(previous.codexTokenIndexAnchor)
        #expect(try #require(previous.codexPendingSourcePricing).isEmpty == false)
        #expect(previous.codexPendingSourcePricingAnchor == originalAnchor)

        // The ignored suffix record changes, while every usage row and the already parsed prefix stay identical.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: UInt64(markerOffset))
        try handle.write(contentsOf: Data("after!".utf8))
        try handle.close()
        let rewrittenData = try Data(contentsOf: file)
        #expect(rewrittenData.prefix(Int(parsedBytes)) == originalData.prefix(Int(parsedBytes)))
        let metadata = CostUsageScanner.codexFileMetadata(fileURL: file)
        #expect(metadata.fileId == previous.codexScanFileId)
        #expect(CostUsageScanner.codexTokenIndexAnchorMatches(parsedAnchor, fileURL: file, metadata: metadata))
        #expect(!CostUsageScanner.codexTokenIndexAnchorMatches(originalAnchor, fileURL: file, metadata: metadata))

        options.maxCodexScanBytesPerRefresh = 100
        options.maxCodexSessionFileBytes = 100
        _ = Self.report(day: day, options: options, elapsed: Double(setupPass + 1))
        let resumed = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
        #expect(resumed.files[file.path]?.codexScanComplete == false)
        #expect(try #require(resumed.files[file.path]?.codexPendingSourcePricing).isEmpty)
        var completed = false
        for pass in (setupPass + 2)..<(setupPass + 40) {
            _ = Self.report(day: day, options: options, elapsed: Double(pass))
            let reopened = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
            if reopened.codexScanCatchUpPending != true {
                completed = true
                break
            }
            if reopened.files[file.path]?.codexScanComplete == false {
                #expect(try #require(reopened.files[file.path]?.codexPendingSourcePricing).isEmpty)
            }
        }
        #expect(completed)
        let final = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
        let rows = try #require(final.files[file.path]?.codexRows)
        #expect(rows.map(\.input) == [200_000, 200_000, 200_000])
        #expect(rows.suffix(2).allSatisfy { $0.unpricedTokens == 200_000 && $0.pricingMode != "priority" })
        #expect(final.files[file.path]?.codexPendingSourcePricing == nil)
        #expect(final.files[file.path]?.codexPendingSourcePricingAnchor == nil)
        let report = Self.cachedReport(cache: final, day: day)
        #expect(report.summary?.totalTokens == 600_000)
        #expect(report.summary?.totalCostUSD == nil)
    }

    @Test
    func `growth after recovery selection retains pricing when the original target still matches`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        let contents = try Self.sourceLines(inputs: [200_000, 200_000, 200_000], day: day, env: env)
            .joined(separator: "\n") + "\n"
        let file = try env.writeCodexSessionFile(day: day, filename: "selected-growth.jsonl", contents: contents)
        let options = Self.options(env: env)
        _ = Self.report(day: day, options: options)
        let canonical = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        try Self.contaminate(file: file, cache: canonical, day: day, env: env, pricingMode: "priority")
        let selected = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let cached = try #require(selected.files[file.path])
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        #expect(CostUsageScanner.codexSourceRowRecoveryPathKeys(
            cache: selected, range: range, roots: [env.codexSessionsRoot]).count == 1)
        let pricing = try #require(CostUsageScanner.codexSourceRowRecoveryPricing(cached, range: range))
        #expect(pricing.values.allSatisfy { $0.pricingMode == "priority" })

        let suffix = try #require(Self.sourceLines(inputs: [50000], day: day.addingTimeInterval(1), env: env).last)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((suffix + "\n").utf8))
        try handle.close()
        let metadata = CostUsageScanner.codexFileMetadata(fileURL: file)
        #expect(metadata.fileId == cached.codexScanFileId)
        #expect(metadata.size > cached.size)
        #expect(try CostUsageScanner.codexTokenIndexAnchorMatches(
            #require(cached.codexTokenIndexAnchor), fileURL: file, metadata: metadata))
        let validated = CostUsageScanner.codexSourcePricingForScan(
            cached: cached,
            metadata: metadata,
            range: range,
            recoveringSourceRows: true)
        #expect(validated == pricing)
    }

    @Test(arguments: [false, true])
    func `interrupted recovery drops pricing when source identity or prefix changes`(replaceFile: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        let lines = try Self.sourceLines(inputs: [200_000, 200_000, 200_000], day: day, env: env)
        let contents = lines.joined(separator: "\n") + "\n"
        let file = try env.writeCodexSessionFile(day: day, filename: "replaced-recovery.jsonl", contents: contents)
        var options = Self.options(env: env)
        _ = Self.report(day: day, options: options)
        var contaminated = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        contaminated.files[file.path]?.codexRows = Self.contaminatedRows(day: day, pricingMode: "priority").map { row in
            var row = row
            row.pricingModel = "gpt-5.5"
            return row
        }
        #expect(!CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: contaminated).catchUpRequired)

        let budget = Int64((lines.prefix(4).joined(separator: "\n") + "\n").utf8.count)
        options.maxCodexScanBytesPerRefresh = budget
        options.maxCodexSessionFileBytes = budget
        _ = Self.report(day: day, options: options, elapsed: 1)
        let interrupted = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
        let previous = try #require(interrupted.files[file.path])
        #expect(previous.codexScanComplete == false)
        let previousIdentity = try #require(previous.codexScanFileId)
        let previousAnchor = try #require(previous.codexTokenIndexAnchor)
        let previousPricing = try #require(previous.codexPendingSourcePricing)
        #expect(!previousPricing.isEmpty)
        #expect(previousPricing.values.allSatisfy { $0.pricingMode == "priority" && $0.pricingModel == "gpt-5.5" })

        if replaceFile {
            try contents.write(to: file, atomically: true, encoding: .utf8)
            #expect(CostUsageScanner.codexFileMetadata(fileURL: file).fileId != previousIdentity)
        } else {
            var rewritten = lines
            // Change only the session header timestamp; every usage identity and token tuple remains equal.
            rewritten[0] = rewritten[0].replacingOccurrences(
                of: env.isoString(for: day),
                with: env.isoString(for: day.addingTimeInterval(1)))
            let replacement = rewritten.joined(separator: "\n") + "\n"
            #expect(replacement != contents)
            #expect(replacement.utf8.count == contents.utf8.count)
            let handle = try FileHandle(forWritingTo: file)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Data(replacement.utf8))
            try handle.close()
            let metadata = CostUsageScanner.codexFileMetadata(fileURL: file)
            #expect(metadata.fileId == previousIdentity)
            #expect(!CostUsageScanner.codexTokenIndexAnchorMatches(
                previousAnchor,
                fileURL: file,
                metadata: metadata))
        }

        _ = Self.report(day: day, options: options, elapsed: 2)
        let restarted = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
        let partial = try #require(restarted.files[file.path])
        #expect(partial.codexScanComplete == false)
        #expect(partial.sessionId == previous.sessionId)
        #expect(try #require(partial.codexPendingSourcePricing).isEmpty)
        #expect(partial.codexRows?.allSatisfy { $0.unpricedTokens == 200_000 } == true)

        var completed = false
        for pass in 3..<30 {
            _ = Self.report(day: day, options: options, elapsed: Double(pass))
            let reopened = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
            if reopened.codexScanCatchUpPending != true {
                completed = true
                break
            }
            if reopened.files[file.path]?.codexScanComplete == false {
                #expect(try #require(reopened.files[file.path]?.codexPendingSourcePricing).isEmpty)
            }
        }
        #expect(completed)
        let final = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
        let usage = try #require(final.files[file.path])
        let rows = try #require(usage.codexRows)
        #expect(rows.map(\.input) == [200_000, 200_000, 200_000])
        #expect(rows.allSatisfy { $0.unpricedTokens == 200_000 })
        #expect(rows.allSatisfy { $0.pricingMode != "priority" && $0.pricingModel == "gpt-5.4" })
        #expect(usage.codexPendingSourcePricing == nil)
        let report = Self.cachedReport(cache: final, day: day)
        #expect(report.summary?.totalTokens == 600_000)
        #expect(report.summary?.totalCostUSD == nil)
    }

    private static func subagentRecoverySourceLines(day: Date, env: CostUsageTestEnvironment) throws -> [String] {
        let timestamp = env.isoString(for: day)
        let prefix: [[String: Any]] = [
            ["type": "session_meta", "ordinal": 0, "timestamp": timestamp, "payload": [
                "id": "synthetic-subagent-session", "forked_from_id": "synthetic-parent-session",
                "timestamp": timestamp, "subagent_history_start_ordinal": 10,
                "source": ["subagent": ["thread_spawn": ["parent_thread_id": "synthetic-parent-session"]]],
            ]],
            ["type": "turn_context", "ordinal": 1, "timestamp": timestamp, "payload": ["model": "gpt-5.4"]],
            ["type": "event_msg", "ordinal": 2, "timestamp": timestamp, "payload": [
                "type": "token_count", "info": [
                    "total_token_usage": ["input_tokens": 100_000, "cached_input_tokens": 0, "output_tokens": 0],
                    "last_token_usage": ["input_tokens": 100_000, "cached_input_tokens": 0, "output_tokens": 0],
                ],
            ]],
            ["type": "turn_context", "ordinal": 10, "timestamp": timestamp, "payload": ["model": "gpt-5.4"]],
            ["type": "event_msg", "ordinal": 11, "timestamp": timestamp, "payload": [
                "type": "task_started", "turn_id": "synthetic-shared-turn",
            ]],
        ]
        return try prefix.map { try env.jsonl([$0]) }
            + (0..<3).map { try self.subagentRecoveryTokenLine(index: $0, day: day, env: env) }
    }

    private static func subagentRecoveryTokenLine(
        index: Int,
        day: Date,
        env: CostUsageTestEnvironment) throws -> String
    {
        try env.jsonl([["type": "event_msg", "ordinal": 12 + index, "timestamp": env.isoString(for: day), "payload": [
            "type": "token_count", "info": [
                "total_token_usage": [
                    "input_tokens": 100_000 + 200_000 * (index + 1), "cached_input_tokens": 0, "output_tokens": 0,
                ],
                "last_token_usage": ["input_tokens": 200_000, "cached_input_tokens": 0, "output_tokens": 0],
            ],
        ]]])
    }
}
