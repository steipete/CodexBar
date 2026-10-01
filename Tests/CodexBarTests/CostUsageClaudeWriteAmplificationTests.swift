import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageClaudeWriteAmplificationTests {
    @Test(arguments: [2, 128], [false, true])
    func `unchanged scans preserve both cache and memo artifacts`(rowCount: Int, forceRescan: Bool) throws {
        let fixture = try Fixture(rowCount: rowCount)
        defer { fixture.env.cleanup() }
        for context in [CostUsageReportContext.regular, .spendDashboard] {
            let initial = try fixture.load(context: context)
            for cycle in 1...3 {
                // Drop the in-process memo as well, exercising the cross-launch baseline.
                CostUsageScanner.evictClaudeReportMemoForTesting(
                    provider: .claude, cacheRoot: fixture.env.cacheRoot, reportContext: context)
                let before = try fixture.stamps(context: context)
                let report = try fixture.load(context: context, cycle: cycle, forceRescan: forceRescan)
                let after = try fixture.stamps(context: context)
                let bytes = zip(before, after).reduce(Int64(0)) { $0 + ($1.0 == $1.1 ? 0 : $1.1.size) }
                print("[claude-json-writes] rows=\(rowCount) context=\(context) force=\(forceRescan) " +
                    "cycle=\(cycle) files=\(zip(before, after).filter { $0 != $1 }.count) bytes=\(bytes)")
                #expect(report.data == initial.data)
                #expect(report.hourly == initial.hourly)
                #expect(report.quotaSlices == initial.quotaSlices)
                #expect(after == before)
                #expect(bytes == 0)
            }
        }
    }

    @Test
    func `identical explicit saves preserve artifact stamps`() throws {
        let fixture = try Fixture(rowCount: 2)
        defer { fixture.env.cleanup() }
        _ = try fixture.load(context: .regular)
        let cacheURL = fixture.cacheURL(context: .regular)
        let cache = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: fixture.env.cacheRoot)
        let memo = try #require(CostUsageClaudeReportMemo.shared.entry(
            provider: .claude, canonicalCachePath: cacheURL.path))
        let before = try fixture.stamps(context: .regular)
        for _ in 0..<3 {
            let saved = try CostUsageClaudeCacheIO.save(
                provider: .claude, cache: cache, cacheRoot: fixture.env.cacheRoot)
            #expect(saved == before[0])
            CostUsageClaudeReportMemo.shared.store(
                provider: .claude,
                canonicalCachePath: cacheURL.path,
                sourceInventory: memo.sourceInventory,
                reportKey: memo.reportKey,
                report: memo.report,
                hasWindowScopedRows: memo.hasWindowScopedRows)
        }
        #expect(try fixture.stamps(context: .regular) == before)
    }

    @Test
    func `unchanged cache artifacts decode once and external rewrites invalidate the memo`() throws {
        let fixture = try Fixture(rowCount: 2)
        defer { fixture.env.cleanup() }
        _ = try fixture.load(context: .regular)

        CostUsageClaudeCacheIO.evictArtifactMemoForTesting(at: fixture.cacheURL(context: .regular))
        let warm = CostUsageScanner.ClaudeScanWorkRecorder()
        let cache = CostUsageScanner.withClaudeScanWorkRecorderForTesting(warm) {
            var loaded = CostUsageClaudeCache()
            for _ in 0..<4 {
                loaded = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: fixture.env.cacheRoot)
            }
            return loaded
        }
        // Repeated reads of an untouched artifact must not repeat its multi-second row decode.
        #expect(warm.snapshot().cacheDecodes == 1)
        #expect(!cache.usage.files.isEmpty)

        var mutated = cache
        mutated.usage.lastScanUnixMs += 1
        try JSONEncoder().encode(mutated).write(to: fixture.cacheURL(context: .regular), options: .atomic)

        let rewritten = CostUsageScanner.ClaudeScanWorkRecorder()
        let reloaded = CostUsageScanner.withClaudeScanWorkRecorderForTesting(rewritten) {
            CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: fixture.env.cacheRoot)
        }
        // A rewrite restamps the artifact, so the stale memo entry must not be served.
        #expect(rewritten.snapshot().cacheDecodes == 1)
        #expect(reloaded.usage.lastScanUnixMs == mutated.usage.lastScanUnixMs)
    }

    @Test
    func `unchanged saves survive decoded artifact eviction without encoding`() throws {
        let fixture = try Fixture(rowCount: 128)
        defer { fixture.env.cleanup() }
        _ = try fixture.load(context: .regular)
        let url = fixture.cacheURL(context: .regular)
        let cache = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: fixture.env.cacheRoot)
        let before = try fixture.stamps(context: .regular)
        let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
        try CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
            for _ in 0..<3 {
                CostUsageClaudeCacheIO.evictArtifactMemoForTesting(at: url)
                _ = try CostUsageClaudeCacheIO.save(provider: .claude, cache: cache, cacheRoot: fixture.env.cacheRoot)
            }
        }
        #expect(recorder.snapshot().cacheEncodes == 0)
        #expect(recorder.persistenceSnapshot().reads == 0)
        #expect(recorder.persistenceSnapshot().writes == 0)
        #expect(try fixture.stamps(context: .regular) == before)
    }

    @Test
    func `changed content writes once without reading back either artifact`() throws {
        let fixture = try Fixture(rowCount: 2)
        defer { fixture.env.cleanup() }
        _ = try fixture.load(context: .regular)
        let url = fixture.cacheURL(context: .regular)
        var cache = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: fixture.env.cacheRoot)
        cache.usage.lastScanUnixMs += 1
        let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
        try CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
            for _ in 0..<3 {
                _ = try CostUsageClaudeCacheIO.save(provider: .claude, cache: cache, cacheRoot: fixture.env.cacheRoot)
            }
        }
        #expect(recorder.snapshot().cacheEncodes == 1)
        #expect(recorder.persistenceSnapshot().writes == 1)
        #expect(recorder.persistenceSnapshot().reads == 0)
        let decoded = try JSONDecoder().decode(CostUsageClaudeCache.self, from: Data(contentsOf: url))
        #expect(decoded.usage == cache.usage)
        #expect(decoded.sourceFileIDs == cache.sourceFileIDs)

        let memo = try #require(CostUsageClaudeReportMemo.shared.entry(
            provider: .claude, canonicalCachePath: url.path))
        var inventory = memo.sourceInventory
        inventory.removeAll()
        let memoRecorder = CostUsageScanner.ClaudeScanWorkRecorder()
        CostUsageScanner.withClaudeScanWorkRecorderForTesting(memoRecorder) {
            for _ in 0..<3 {
                CostUsageClaudeReportMemo.shared.store(
                    provider: .claude,
                    canonicalCachePath: url.path,
                    sourceInventory: inventory,
                    reportKey: memo.reportKey,
                    report: memo.report,
                    hasWindowScopedRows: memo.hasWindowScopedRows)
            }
        }
        #expect(memoRecorder.persistenceSnapshot().writes == 1)
        #expect(memoRecorder.persistenceSnapshot().reads == 0)
        CostUsageClaudeReportMemo.shared.evict(provider: .claude, canonicalCachePath: url.path)
        let loaded = try #require(CostUsageClaudeReportMemo.shared.entry(
            provider: .claude, canonicalCachePath: url.path))
        #expect(loaded.sourceInventory.isEmpty)
        #expect(loaded.report.data == memo.report.data)
        #expect(loaded.report.hourly == memo.report.hourly)
        #expect(loaded.report.quotaSlices == memo.report.quotaSlices)
    }

    @Test
    func `identical external replacements still rewrite with matching size and mtime`() throws {
        let fixture = try Fixture(rowCount: 2)
        defer { fixture.env.cleanup() }
        _ = try fixture.load(context: .regular)
        let url = fixture.cacheURL(context: .regular)
        let memoURL = CostUsageClaudeReportMemo.reportMemoFileURL(cacheFileURL: url)
        for artifactURL in [url, memoURL] {
            try FileManager.default.setAttributes([.modificationDate: fixture.day], ofItemAtPath: artifactURL.path)
        }
        CostUsageClaudeReportMemo.shared.evict(provider: .claude, canonicalCachePath: url.path)
        let memo = try #require(CostUsageClaudeReportMemo.shared.entry(
            provider: .claude, canonicalCachePath: url.path))
        let cache = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: fixture.env.cacheRoot)
        let before = try fixture.stamps(context: .regular)
        for (index, artifactURL) in [url, memoURL].enumerated() {
            try Data(contentsOf: artifactURL).write(to: artifactURL, options: .atomic)
            try FileManager.default.setAttributes([.modificationDate: fixture.day], ofItemAtPath: artifactURL.path)
            let replacement = try #require(CostUsageClaudeFileStamp.read(at: artifactURL))
            #expect(replacement.size == before[index].size)
            #expect(replacement.modifiedSeconds == before[index].modifiedSeconds)
            #expect(replacement.modifiedNanoseconds == before[index].modifiedNanoseconds)
            #expect(replacement.fileID != before[index].fileID)
        }
        let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
        try CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
            _ = try CostUsageClaudeCacheIO.save(provider: .claude, cache: cache, cacheRoot: fixture.env.cacheRoot)
            CostUsageClaudeReportMemo.shared.store(
                provider: .claude,
                canonicalCachePath: url.path,
                sourceInventory: memo.sourceInventory,
                reportKey: memo.reportKey,
                report: memo.report,
                hasWindowScopedRows: memo.hasWindowScopedRows)
        }
        #expect(recorder.snapshot().cacheEncodes == 1)
        #expect(recorder.persistenceSnapshot().writes == 2)
        #expect(recorder.persistenceSnapshot().reads == 0)
    }

    @Test
    func `legacy sorted JSON loads and rebuilt identical content preserves stamps`() throws {
        let fixture = try Fixture(rowCount: 2)
        defer { fixture.env.cleanup() }
        _ = try fixture.load(context: .regular)
        let url = fixture.cacheURL(context: .regular)
        let original = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: fixture.env.cacheRoot)
        // The current release's encoder and atomic replacement path, without any new identity memo.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let legacyBytes = try encoder.encode(original)
        let temporaryURL = url.appendingPathExtension("legacy")
        try legacyBytes.write(to: temporaryURL)
        #expect(rename(temporaryURL.path, url.path) == 0)
        CostUsageClaudeCacheIO.evictArtifactMemoForTesting(at: url)
        var loaded = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: fixture.env.cacheRoot)
        #expect(loaded.usage == original.usage)
        #expect(loaded.sourceFileIDs == original.sourceFileIDs)
        let before = try #require(CostUsageClaudeFileStamp.read(at: url))
        let usage = loaded.usage
        loaded.usage = usage // A rebuilt value has a new UUID even when its serialized bytes are identical.
        #expect(loaded.contentID != original.contentID)
        let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
        try CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
            for _ in 0..<2 {
                _ = try CostUsageClaudeCacheIO.save(provider: .claude, cache: loaded, cacheRoot: fixture.env.cacheRoot)
            }
        }
        #expect(recorder.snapshot().cacheEncodes == 1)
        #expect(recorder.persistenceSnapshot().writes == 0)
        #expect(recorder.persistenceSnapshot().reads == 0)
        #expect(CostUsageClaudeFileStamp.read(at: url) == before)
        #expect(try Data(contentsOf: url) == legacyBytes)
    }

    @Test
    func `retained row encoding stays compact and preserves every field`() throws {
        let row = CostUsageScanner.ClaudeUsageRow(
            dayKey: "2026-07-01",
            model: "synthetic-model",
            sessionId: "session",
            messageId: "message",
            requestId: "request",
            timestampUnixMs: 123,
            isSidechain: true,
            pathRole: .subagent,
            input: 1,
            cacheRead: 2,
            cacheCreate: 3,
            cacheCreate1h: 4,
            output: 5,
            costNanos: 6,
            costPriced: false,
            isIncomplete: true)
        let data = try JSONEncoder().encode(row)
        #expect(data.count < 240)
        #expect(try JSONDecoder().decode(CostUsageScanner.ClaudeUsageRow.self, from: data) == row)
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(fields.count == 16)
        #expect(fields["d"] as? String == row.dayKey)
    }

    @Test
    func `saved artifacts are reused without decoding or encoding identical content`() throws {
        let fixture = try Fixture(rowCount: 128)
        defer { fixture.env.cleanup() }
        _ = try fixture.load(context: .regular)
        let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
        try CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
            for cycle in 1...3 {
                var cache = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: fixture.env.cacheRoot)
                let before = try fixture.stamps(context: .regular)
                _ = try CostUsageClaudeCacheIO.save(
                    provider: .claude, cache: cache, cacheRoot: fixture.env.cacheRoot)
                #expect(try fixture.stamps(context: .regular) == before)
                cache.usage.lastScanUnixMs += Int64(cycle)
                _ = try CostUsageClaudeCacheIO.save(
                    provider: .claude, cache: cache, cacheRoot: fixture.env.cacheRoot)
                #expect(CostUsageClaudeCacheIO.load(
                    provider: .claude, cacheRoot: fixture.env.cacheRoot).usage == cache.usage)
            }
        }
        #expect(recorder.snapshot().cacheDecodes == 0)
        #expect(recorder.snapshot().cacheEncodes == 3)
    }

    @Test
    func `identical save checks cancellation and cannot ignore an external replacement`() throws {
        let fixture = try Fixture(rowCount: 2)
        defer { fixture.env.cleanup() }
        _ = try fixture.load(context: .regular)
        let cache = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: fixture.env.cacheRoot)
        let before = try fixture.stamps(context: .regular)
        #expect(throws: CancellationError.self) {
            try CostUsageClaudeCacheIO.save(
                provider: .claude,
                cache: cache,
                cacheRoot: fixture.env.cacheRoot,
                checkCancellation: { throw CancellationError() })
        }
        #expect(try fixture.stamps(context: .regular) == before)
        var replacement = cache
        replacement.usage.lastScanUnixMs += 1
        let url = fixture.cacheURL(context: .regular)
        try JSONEncoder().encode(replacement).write(to: url, options: .atomic)
        _ = try CostUsageClaudeCacheIO.save(provider: .claude, cache: cache, cacheRoot: fixture.env.cacheRoot)
        let restored = try JSONDecoder().decode(CostUsageClaudeCache.self, from: Data(contentsOf: url))
        #expect(restored.usage == cache.usage)
        #expect(restored.sourceFileIDs == cache.sourceFileIDs)
    }

    @Test
    func `canonically equal model edits persist exact UTF8 bytes`() throws {
        let fixture = try Fixture(rowCount: 1)
        defer { fixture.env.cleanup() }
        _ = try fixture.load(context: .regular)
        var cache = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: fixture.env.cacheRoot)
        let path = try #require(cache.usage.files.keys.first)
        let row = try #require(cache.usage.files[path]?.claudeRows?.first)
        var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
        let models = ["synthetic-\u{00E9}", "synthetic-e\u{0301}"]
        #expect(models[0] == models[1])
        for model in models {
            fields["m"] = model
            let data = try JSONSerialization.data(withJSONObject: fields)
            cache.usage.files[path]?.claudeRows = try [JSONDecoder().decode(
                CostUsageScanner.ClaudeUsageRow.self,
                from: data)]
            _ = try CostUsageClaudeCacheIO.save(provider: .claude, cache: cache, cacheRoot: fixture.env.cacheRoot)
            let stored = try JSONDecoder().decode(
                CostUsageClaudeCache.self, from: Data(contentsOf: fixture.cacheURL(context: .regular)))
            #expect(stored.usage.files[path]?.claudeRows?.first?.model.utf8.elementsEqual(model.utf8) == true)
        }
    }

    @Test
    func `schema three rows rebuild from transcripts without changing totals`() throws {
        let fixture = try Fixture(rowCount: 1)
        defer { fixture.env.cleanup() }
        let initial = try fixture.load(context: .regular)
        let url = fixture.cacheURL(context: .regular)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["version"] = 3
        var files = try #require(object["files"] as? [String: [String: Any]])
        let path = try #require(files.keys.first)
        files[path]?["claudeRows"] = [[
            "dayKey": "2026-07-01", "model": "claude-sonnet-4-20250514", "messageId": "message-0",
            "requestId": "request-0", "timestampUnixMs": Int64(fixture.day.timeIntervalSince1970 * 1000),
            "isSidechain": false, "pathRole": "parent", "input": 10, "cacheRead": 0, "cacheCreate": 0,
            "output": 5, "costNanos": 105_000, "costPriced": true,
        ]]
        object["files"] = files
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
        CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: fixture.env.cacheRoot)
        let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
        let upgraded = try CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
            try fixture.load(context: .regular, cycle: 1)
        }
        #expect(upgraded.data == initial.data)
        #expect(upgraded.hourly == initial.hourly)
        #expect(upgraded.quotaSlices == initial.quotaSlices)
        #expect(recorder.snapshot().transcriptParses == 1)
        #expect(recorder.snapshot().incrementalTranscriptParses == 0)
        #expect(CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: fixture.env.cacheRoot).usage.version == 4)
    }

    @Test
    func `changed usage persists once and a cancelled save preserves the artifacts`() throws {
        let fixture = try Fixture(rowCount: 2)
        defer { fixture.env.cleanup() }
        let initial = try fixture.load(context: .regular)
        let before = try fixture.stamps(context: .regular)
        _ = try fixture.env.writeClaudeProjectFile(
            relativePath: "added.jsonl", contents: fixture.event(index: 500))
        let changed = try fixture.load(context: .regular, cycle: 1)
        #expect(changed.summary?.totalInputTokens == (initial.summary?.totalInputTokens ?? 0) + 10)
        let after = try fixture.stamps(context: .regular)
        #expect(after[0] != before[0])
        #expect(after[1] != before[1])
        var cache = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: fixture.env.cacheRoot)
        cache.usage.lastScanUnixMs += 1
        #expect(throws: CancellationError.self) {
            try CostUsageClaudeCacheIO.save(
                provider: .claude,
                cache: cache,
                cacheRoot: fixture.env.cacheRoot,
                checkCancellation: { throw CancellationError() })
        }
        #expect(try fixture.stamps(context: .regular) == after)
        _ = try fixture.load(context: .regular, cycle: 2)
        #expect(try fixture.stamps(context: .regular) == after)
        CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: fixture.env.cacheRoot)
        let cold = try fixture.load(context: .regular, cycle: 3)
        #expect(cold.data == changed.data)
        #expect(cold.quotaSlices == changed.quotaSlices)
    }

    @Test
    func `memo validates the requested timezone and artifact schema on every hit`() throws {
        let fixture = try Fixture(rowCount: 2)
        defer { fixture.env.cleanup() }
        _ = try fixture.load(context: .regular)
        let cache = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: fixture.env.cacheRoot)
        var differentCalendar = Calendar(identifier: .gregorian)
        differentCalendar.timeZone = try #require(TimeZone(identifier:
            cache.usage.timeZoneIdentifier == "Asia/Tokyo" ? "America/Los_Angeles" : "Asia/Tokyo"))
        #expect(differentCalendar.timeZone.identifier != cache.usage.timeZoneIdentifier)
        #expect(CostUsageClaudeCacheIO.load(
            provider: .claude, cacheRoot: fixture.env.cacheRoot, calendar: differentCalendar).usage.files.isEmpty)
        #expect(!CostUsageClaudeCacheIO.load(
            provider: .claude, cacheRoot: fixture.env.cacheRoot, calendar: .current).usage.files.isEmpty)
        var invalid = cache
        invalid.usage.version = -1
        try JSONEncoder().encode(invalid).write(to: fixture.cacheURL(context: .regular), options: .atomic)
        for _ in 0..<2 {
            #expect(CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: fixture.env.cacheRoot).usage.files
                .isEmpty)
        }
    }

    @Test
    func `same size and mtime replacement invalidates by identity and callers cannot mutate the memo`() throws {
        let fixture = try Fixture(rowCount: 2)
        defer { fixture.env.cleanup() }
        _ = try fixture.load(context: .regular)
        let url = fixture.cacheURL(context: .regular)
        try FileManager.default.setAttributes([.modificationDate: fixture.day], ofItemAtPath: url.path)
        let original = try #require(CostUsageClaudeFileStamp.read(at: url))
        var cache = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: fixture.env.cacheRoot)
        let initialTime = cache.usage.lastScanUnixMs
        cache.usage.lastScanUnixMs += 1
        #expect(CostUsageClaudeCacheIO.load(
            provider: .claude, cacheRoot: fixture.env.cacheRoot).usage.lastScanUnixMs == initialTime)
        _ = try CostUsageClaudeCacheIO.save(provider: .claude, cache: cache, cacheRoot: fixture.env.cacheRoot)
        try FileManager.default.setAttributes([.modificationDate: fixture.day], ofItemAtPath: url.path)
        let replacement = try #require(CostUsageClaudeFileStamp.read(at: url))
        #expect(original.fileID != replacement.fileID)
        #expect(original.size == replacement.size)
        #expect(original.modifiedSeconds == replacement.modifiedSeconds)
        #expect(original.modifiedNanoseconds == replacement.modifiedNanoseconds)
        #expect(CostUsageClaudeCacheIO.load(
            provider: .claude, cacheRoot: fixture.env.cacheRoot).usage.lastScanUnixMs == initialTime + 1)
        try FileManager.default.removeItem(at: url)
        #expect(CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: fixture.env.cacheRoot).usage.files.isEmpty)
    }

    @Test
    func `memo separates provider report context and cache root`() throws {
        let fixture = try Fixture(rowCount: 2)
        defer { fixture.env.cleanup() }
        _ = try fixture.load(context: .regular)
        var cache = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: fixture.env.cacheRoot)
        let scopes: [(UsageProvider, CostUsageReportContext, URL)] = [
            (.claude, .regular, fixture.env.cacheRoot),
            (.claude, .spendDashboard, fixture.env.cacheRoot),
            (.vertexai, .regular, fixture.env.cacheRoot),
            (.vertexai, .spendDashboard, fixture.env.cacheRoot),
            (.claude, .regular, fixture.env.root.appendingPathComponent("other-cache")),
        ]
        for (index, scope) in scopes.enumerated() {
            cache.usage.lastScanUnixMs = Int64(index + 1)
            _ = try CostUsageClaudeCacheIO.save(
                provider: scope.0, cache: cache, cacheRoot: scope.2, reportContext: scope.1)
        }
        for _ in 0..<2 {
            for (index, scope) in scopes.enumerated().reversed() {
                #expect(CostUsageClaudeCacheIO.load(
                    provider: scope.0,
                    cacheRoot: scope.2,
                    reportContext: scope.1).usage.lastScanUnixMs == Int64(index + 1))
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEXBAR_ARTIFACT_BENCHMARK"] == "1"))
    func `synthetic artifact decode benchmark`() throws {
        let fixture = try Fixture(rowCount: 4096)
        defer { fixture.env.cleanup() }
        _ = try fixture.load(context: .regular)
        let url = fixture.cacheURL(context: .regular)
        let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
        try CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
            let coldStart = ContinuousClock.now
            for _ in 0..<5 {
                CostUsageClaudeCacheIO.evictArtifactMemoForTesting(at: url)
                #expect(CostUsageClaudeCacheIO.load(
                    provider: .claude, cacheRoot: fixture.env.cacheRoot).usage.files.count == 1)
            }
            let cold = coldStart.duration(to: .now)
            let warmStart = ContinuousClock.now
            for _ in 0..<5 {
                #expect(CostUsageClaudeCacheIO.load(
                    provider: .claude, cacheRoot: fixture.env.cacheRoot).usage.files.count == 1)
            }
            let warm = warmStart.duration(to: .now)
            let bytes = try Data(contentsOf: url).count
            print("[artifact-benchmark] rows=4096 bytes=\(bytes) reads=5 cold=\(cold) warm=\(warm)")
        }
        #expect(recorder.snapshot().cacheDecodes == 5)
    }

    @Test
    func `switching source roots with a warm artifact never borrows prior rows`() throws {
        let fixture = try Fixture(rowCount: 2)
        defer { fixture.env.cleanup() }
        #expect(try fixture.load(context: .regular).summary?.totalInputTokens == 20)
        let otherRoot = fixture.env.root.appendingPathComponent("other-projects")
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        try fixture.event(index: 700).write(
            to: otherRoot.appendingPathComponent("other.jsonl"), atomically: true, encoding: .utf8)
        let report = try CostUsageScanner.loadDailyReportCancellable(
            provider: .claude,
            since: fixture.day.addingTimeInterval(-29 * 86400),
            until: fixture.day,
            now: fixture.day,
            options: .init(claudeProjectsRoots: [otherRoot], cacheRoot: fixture.env.cacheRoot),
            reportContext: .regular,
            checkCancellation: nil)
        #expect(report.summary?.totalInputTokens == 10)
        #expect(try fixture.load(context: .regular).summary?.totalInputTokens == 20)
    }

    struct Fixture {
        let env: CostUsageTestEnvironment
        let day: Date
        let identityPadding: String

        init(rowCount: Int, identityLength: Int = 0) throws {
            self.identityPadding = String(repeating: "s", count: identityLength)
            self.env = try CostUsageTestEnvironment()
            self.day = try self.env.makeLocalNoon(year: 2026, month: 7, day: 1)
            _ = try self.env.writeClaudeProjectFile(
                relativePath: "session.jsonl", contents: (0..<rowCount).map(self.event).joined())
        }

        func event(index: Int) throws -> String {
            try self.env.jsonl([[
                "type": "assistant", "timestamp": self.env.isoString(for: self.day.addingTimeInterval(Double(index))),
                "requestId": "request-\(self.identityPadding)\(index)",
                "message": [
                    "id": "message-\(self.identityPadding)\(index)",
                    "model": "claude-sonnet-4-20250514",
                    "usage": ["input_tokens": 10, "output_tokens": 5],
                ],
            ]])
        }

        func cacheURL(context: CostUsageReportContext) -> URL {
            CostUsageClaudeCacheIO.cacheFileURL(
                provider: .claude,
                cacheRoot: self.env.cacheRoot,
                reportContext: context)
        }

        func stamps(context: CostUsageReportContext) throws -> [CostUsageClaudeFileStamp] {
            let cache = self.cacheURL(context: context)
            return try [cache, CostUsageClaudeReportMemo.reportMemoFileURL(cacheFileURL: cache)].map {
                try #require(CostUsageClaudeFileStamp.read(at: $0))
            }
        }

        func load(
            context: CostUsageReportContext,
            cycle: Int = 0,
            forceRescan: Bool = false) throws -> CostUsageDailyReport
        {
            var options = CostUsageScanner.Options(
                claudeProjectsRoots: [self.env.claudeProjectsRoot], cacheRoot: self.env.cacheRoot)
            options.refreshMinIntervalSeconds = 0
            options.forceRescan = forceRescan
            return try CostUsageScanner.loadDailyReportCancellable(
                provider: .claude,
                since: self.day.addingTimeInterval(context == .regular ? -29 * 86400 : -364 * 86400),
                until: self.day,
                now: self.day.addingTimeInterval(Double(cycle * 900)),
                options: options,
                reportContext: context,
                checkCancellation: nil)
        }
    }
}
