// swiftlint:disable file_length
import Foundation
import Testing
@testable import CodexBarCore

// swiftlint:disable:next type_body_length
struct CostUsageCacheTests {
    @Test
    func `legacy codex token cache decodes without reasoning while current rows round trip it`() throws {
        let legacyTotals = try JSONDecoder().decode(
            CostUsageCodexTotals.self,
            from: Data(#"{"input":10,"cached":2,"output":4}"#.utf8))
        #expect(legacyTotals.reasoning == nil)

        let legacyRow = try JSONDecoder().decode(
            CostUsageScanner.CodexUsageRow.self,
            from: Data(#"{"day":"2026-07-17","model":"gpt-5.5","input":10,"cached":2,"output":4}"#.utf8))
        #expect(legacyRow.reasoning == nil)

        let currentRow = CostUsageScanner.CodexUsageRow(
            day: "2026-07-17",
            model: "gpt-5.5",
            turnID: "turn",
            eventIndex: 1,
            input: 10,
            cached: 2,
            output: 4,
            reasoning: 3)
        let roundTripped = try JSONDecoder().decode(
            CostUsageScanner.CodexUsageRow.self,
            from: JSONEncoder().encode(currentRow))
        #expect(roundTripped.reasoning == 3)
    }

    @Test
    func `cache file URL uses provider artifact versions`() {
        let root = URL(fileURLWithPath: "/tmp/codexbar-cost-cache", isDirectory: true)

        let codexURL = CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: root)
        let claudeURL = CostUsageCacheIO.cacheFileURL(provider: .claude, cacheRoot: root)
        let vertexURL = CostUsageCacheIO.cacheFileURL(provider: .vertexai, cacheRoot: root)

        #expect(codexURL.lastPathComponent == "codex-v11.json")
        #expect(claudeURL.lastPathComponent == "claude-v6.json")
        #expect(vertexURL.lastPathComponent == "vertexai-v6.json")
    }

    @Test
    func `cost cache ignores predecessor artifact with persisted offset`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyURL = root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("codex-v9.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let producerKey = try #require(CostUsageCacheIO.currentProducerKey(provider: .codex))
        let legacy = """
        {
          "version": 1,
          "producerKey": "\(producerKey)",
          "lastScanUnixMs": 999,
          "files": {
            "/tmp/session.jsonl": {
              "mtimeUnixMs": 1,
              "size": 100,
              "days": {},
              "parsedBytes": 100
            }
          },
          "days": {}
        }
        """
        try legacy.write(to: legacyURL, atomically: false, encoding: .utf8)

        let loaded = CostUsageCacheIO.load(provider: .codex, cacheRoot: root)

        #expect(loaded.lastScanUnixMs == 0)
        #expect(loaded.files.isEmpty)
    }

    @Test
    func `Pi session cache ignores predecessor artifact with persisted offset`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyURL = root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("pi-sessions-v7.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        var legacy = PiSessionCostCache(version: 7)
        legacy.lastScanUnixMs = 999
        legacy.files = [
            "/tmp/session.jsonl": PiSessionFileUsage(
                mtimeUnixMs: 1,
                size: 100,
                parsedBytes: 100,
                lastModelContext: nil,
                contributions: [:]),
        ]
        try JSONEncoder().encode(legacy).write(to: legacyURL)

        let loaded = PiSessionCostCacheIO.load(cacheRoot: root)

        #expect(loaded.version == 8)
        #expect(loaded.lastScanUnixMs == 0)
        #expect(loaded.files.isEmpty)
    }

    @Test
    func `cache load requires matching producer key`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var cache = CostUsageCache()
        cache.lastScanUnixMs = 123
        cache.days = ["2026-05-18": ["gpt-5.5": [1, 2, 3]]]

        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111")

        let loaded = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111")
        #expect(loaded.producerKey == "codex:cu:p1111111111111111")
        #expect(loaded.lastScanUnixMs == 123)
        #expect(loaded.days["2026-05-18"]?["gpt-5.5"] == [1, 2, 3])

        let stale = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: root,
            producerKey: "codex:cu:p2222222222222222")
        #expect(stale.lastScanUnixMs == 0)
        #expect(stale.files.isEmpty)
        #expect(stale.days.isEmpty)

        let migration = CostUsageCacheIO.loadCodexForMigration(
            cacheRoot: root,
            producerKey: "codex:cu:p2222222222222222")
        #expect(migration.cache.days.isEmpty)
        #expect(migration.incompatibleCache?.producerKey == "codex:cu:p1111111111111111")
        #expect(migration.incompatibleCache?.days["2026-05-18"]?["gpt-5.5"] == [1, 2, 3])
    }

    @Test
    func `published usage row generations ignore report compatibility filters`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        func sidecarState(_ generation: String) -> CostUsageCodexUsageRowSidecarState {
            CostUsageCodexUsageRowSidecarState(
                generation: generation,
                rowCount: 1,
                nextUsageRowIndex: 1,
                prefixDigest: String(repeating: "0", count: 64),
                coverageSinceKey: "2026-05-01",
                coverageUntilKey: "2026-05-31",
                pricingKey: "pricing-v1",
                priorityMetadataKey: "priority-v1")
        }

        var first = CostUsageFileUsage(mtimeUnixMs: 1, size: 10, days: [:])
        first.codexUsageRowSidecarState = sidecarState("generation-first")
        var second = CostUsageFileUsage(mtimeUnixMs: 2, size: 20, days: [:])
        second.codexUsageRowSidecarState = sidecarState("generation-second")
        var cache = CostUsageCache()
        cache.files = [
            "/sessions/first.jsonl": first,
            "/sessions/second.jsonl": second,
            "/sessions/inline.jsonl": CostUsageFileUsage(mtimeUnixMs: 3, size: 30, days: [:]),
        ]
        var foreignCalendar = Calendar(identifier: .gregorian)
        foreignCalendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: root,
            producerKey: "codex:cu:pincompatible",
            calendar: foreignCalendar)

        let generations = CostUsageCacheIO.loadPublishedCodexUsageRowGenerationIDs(cacheRoot: root)
        #expect(generations == Set(["generation-first", "generation-second"]))
    }

    @Test
    func `published usage row generation load fails closed`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(CostUsageCacheIO.loadPublishedCodexUsageRowGenerationIDs(cacheRoot: root) == Set<String>())

        let url = CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: root)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("{not-json".utf8).write(to: url)
        #expect(CostUsageCacheIO.loadPublishedCodexUsageRowGenerationIDs(cacheRoot: root) == nil)

        var unsupported = CostUsageCache()
        unsupported.version = 2
        try JSONEncoder().encode(unsupported).write(to: url)
        #expect(CostUsageCacheIO.loadPublishedCodexUsageRowGenerationIDs(cacheRoot: root) == nil)

        let validData = try JSONEncoder().encode(CostUsageCache())
        try validData.write(to: url)
        #expect(CostUsageCacheIO.loadPublishedCodexUsageRowGenerationIDs(
            cacheRoot: root,
            maxCacheBytes: validData.count - 1) == nil)
    }

    @Test
    func `legacy cache without producer key is ignored`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: root)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let legacy = """
        {
          "version": 1,
          "lastScanUnixMs": 999,
          "files": {},
          "days": {
            "2026-05-18": {
              "gpt-5": [1, 0, 0]
            }
          }
        }
        """
        try legacy.write(to: url, atomically: false, encoding: .utf8)

        let loaded = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111")

        #expect(loaded.lastScanUnixMs == 0)
        #expect(loaded.days.isEmpty)
    }

    @Test
    func `current codex cache rejects pre interleave containment producers`() throws {
        // Interleave containment (#2037) changed cumulative delta semantics, so caches from
        // previously compatible parser hashes must be rebuilt instead of reused.
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        for legacyProducerKey in ["codex:cu:p3c27f997569eb3c5", "codex:cu:pc54070a94f6419ea"] {
            var cache = CostUsageCache()
            cache.lastScanUnixMs = 123
            cache.days = ["2026-05-18": ["gpt-5.5": [1, 2, 3]]]
            CostUsageCacheIO.save(
                provider: .codex,
                cache: cache,
                cacheRoot: root,
                producerKey: legacyProducerKey)

            let loaded = CostUsageCacheIO.load(provider: .codex, cacheRoot: root)

            #expect(loaded.lastScanUnixMs == 0)
            #expect(loaded.days.isEmpty)
        }
    }

    @Test
    func `current codex cache accepts append resume and sidecar predecessors`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        for producerKey in [
            "codex:cu:p843ca061c36bbea1",
            "codex:cu:p6c0f1fa950e63467",
            "codex:cu:p89e80f722cad05c8",
            "codex:cu:pcdc205df2dba1a53",
        ] {
            var cache = CostUsageCache()
            cache.lastScanUnixMs = 123
            cache.days = ["2026-05-18": ["gpt-5.5": [1, 2, 3]]]
            CostUsageCacheIO.save(
                provider: .codex,
                cache: cache,
                cacheRoot: root,
                producerKey: producerKey)

            let loaded = CostUsageCacheIO.load(provider: .codex, cacheRoot: root)
            let migration = CostUsageCacheIO.loadCodexForMigration(cacheRoot: root)

            #expect(loaded.lastScanUnixMs == 123)
            #expect(loaded.days["2026-05-18"]?["gpt-5.5"] == [1, 2, 3])
            #expect(migration.cache.lastScanUnixMs == 123)
            #expect(migration.incompatibleCache == nil)
        }
    }

    @Test
    func `current codex cache accepts calendar normalization predecessors`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Caches persisted by builds since the bounded-cost-cache work stay loadable: the
        // catch-up report calendar normalization did not change stored totals or cache
        // layout, so upgrading must not force a rebuild.
        for (index, producerKey) in [
            "codex:cu:paa27d287348e79b5",
            "codex:cu:p6c0f1fa950e63467",
            "codex:cu:p37aedd661c4272a8",
            "codex:cu:p1cd29792d9ca2b11",
        ].enumerated() {
            let root = root.appendingPathComponent("case-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var cache = CostUsageCache()
            cache.lastScanUnixMs = 456
            cache.days = ["2026-07-02": ["gpt-5.5": [1, 2, 3]]]
            CostUsageCacheIO.save(
                provider: .codex,
                cache: cache,
                cacheRoot: root,
                producerKey: producerKey)

            let loaded = CostUsageCacheIO.load(provider: .codex, cacheRoot: root)
            let migration = CostUsageCacheIO.loadCodexForMigration(cacheRoot: root)

            #expect(loaded.lastScanUnixMs == 456)
            #expect(loaded.days["2026-07-02"]?["gpt-5.5"] == [1, 2, 3])
            #expect(migration.cache.lastScanUnixMs == 456)
            #expect(migration.incompatibleCache == nil)
        }
    }

    @Test
    func `non codex cache does not require producer key`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = CostUsageCacheIO.cacheFileURL(provider: .claude, cacheRoot: root)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let legacy = """
        {
          "version": 1,
          "lastScanUnixMs": 999,
          "files": {},
          "days": {
            "2026-05-18": {
              "claude-sonnet-4-5": [1, 0, 0]
            }
          }
        }
        """
        try legacy.write(to: url, atomically: false, encoding: .utf8)

        let loaded = CostUsageCacheIO.load(provider: .claude, cacheRoot: root)

        #expect(loaded.lastScanUnixMs == 999)
        #expect(loaded.days["2026-05-18"]?["claude-sonnet-4-5"] == [1, 0, 0])
    }

    @Test
    func `current producer key uses generated parser hash for codex only`() {
        let codexKey = CostUsageCacheIO.currentProducerKey(
            provider: .codex,
            parserHash: "abc1234567890def")
        let standaloneKey = CostUsageCacheIO.currentProducerKey(
            provider: .claude,
            parserHash: "abc1234567890def")

        #expect(codexKey == "codex:cu:pabc1234567890def")
        #expect(standaloneKey == nil)
    }

    @Test
    func `generated parser hash is stable short lowercase hex`() {
        let hash = CodexParserHash.value

        #expect(hash.range(of: #"^[0-9a-f]{16}$"#, options: .regularExpression) != nil)
        #expect(CostUsageCacheIO.currentProducerKey(provider: .codex) == "codex:cu:p\(hash)")
    }

    @Test
    func `save prunes out-of-window files when over the entry budget`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var cache = CostUsageCache()
        cache.scanSinceKey = "2026-06-01"
        cache.scanUntilKey = "2026-07-01"
        cache.days = [
            "2026-06-10": ["gpt-5.5": [10, 0, 0]],
            "2026-06-20": ["gpt-5.5": [20, 0, 0]],
            "2026-04-10": ["gpt-5.5": [99, 0, 0]],
        ]
        cache.files = [
            "/sessions/2026-06-10.jsonl": CostUsageFileUsage(
                mtimeUnixMs: 1,
                size: 100,
                days: ["2026-06-10": ["gpt-5.5": [10, 0, 0]]]),
            "/sessions/2026-06-20.jsonl": CostUsageFileUsage(
                mtimeUnixMs: 1,
                size: 100,
                days: ["2026-06-20": ["gpt-5.5": [20, 0, 0]]]),
            "/sessions/2026-04-10.jsonl": CostUsageFileUsage(
                mtimeUnixMs: 1,
                size: 100,
                days: ["2026-04-10": ["gpt-5.5": [99, 0, 0]]]),
        ]

        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111",
            maxCacheEntries: 2)

        let loaded = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111")
        #expect(loaded.files.keys.sorted() == [
            "/sessions/2026-06-10.jsonl",
            "/sessions/2026-06-20.jsonl",
        ])
        #expect(loaded.days["2026-04-10"] == nil)
        #expect(loaded.days["2026-06-10"]?["gpt-5.5"] == [10, 0, 0])
        #expect(loaded.days["2026-06-20"]?["gpt-5.5"] == [20, 0, 0])
    }

    @Test
    func `save prunes out-of-window files when the previous artifact exceeds the byte budget`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: root)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(repeating: 0x20, count: 4096).write(to: url)

        var cache = CostUsageCache()
        cache.scanSinceKey = "2026-06-01"
        cache.scanUntilKey = "2026-07-01"
        cache.days = [
            "2026-06-10": ["gpt-5.5": [1, 0, 0]],
            "2026-04-10": ["gpt-5.5": [9, 0, 0]],
        ]
        cache.files = [
            "/sessions/2026-06-10.jsonl": CostUsageFileUsage(
                mtimeUnixMs: 1,
                size: 100,
                days: ["2026-06-10": ["gpt-5.5": [1, 0, 0]]]),
            "/sessions/2026-04-10.jsonl": CostUsageFileUsage(
                mtimeUnixMs: 1,
                size: 100,
                days: ["2026-04-10": ["gpt-5.5": [9, 0, 0]]]),
        ]

        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111",
            maxCacheBytes: 1024,
            maxCacheEntries: 100)

        let loaded = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111")
        #expect(Array(loaded.files.keys) == ["/sessions/2026-06-10.jsonl"])
        #expect(loaded.days["2026-04-10"] == nil)
        #expect(loaded.days["2026-06-10"]?["gpt-5.5"] == [1, 0, 0])
    }

    @Test
    func `save never drops in-window files even when over the entry budget`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var cache = CostUsageCache()
        cache.scanSinceKey = "2026-06-01"
        cache.scanUntilKey = "2026-07-01"
        cache.days = [
            "2026-06-10": ["gpt-5.5": [1, 0, 0]],
            "2026-06-20": ["gpt-5.5": [2, 0, 0]],
            "2026-06-28": ["gpt-5.5": [3, 0, 0]],
        ]
        for (index, day) in ["2026-06-10", "2026-06-20", "2026-06-28"].enumerated() {
            cache.files["/sessions/\(day).jsonl"] = CostUsageFileUsage(
                mtimeUnixMs: Int64(index),
                size: 100,
                days: [day: ["gpt-5.5": [index + 1, 0, 0]]])
        }

        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111",
            maxCacheEntries: 2)

        let loaded = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111")
        #expect(loaded.files.count == 3)
        #expect(loaded.days.count == 3)
    }

    @Test
    func `load refuses oversized cache artifacts`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: root)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        var payload = Data(
            #"{"version":1,"producerKey":"codex:cu:p1111111111111111","files":{},"days":{}}"#.utf8)
        payload.append(Data(repeating: 0x20, count: 2048))
        try payload.write(to: url)

        let loaded = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111",
            maxCacheBytes: 1024)

        #expect(loaded.files.isEmpty)
        #expect(loaded.days.isEmpty)
    }

    @Test
    func `save preserves out-of-window fork parents during budget pruning`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var cache = CostUsageCache()
        cache.scanSinceKey = "2026-06-01"
        cache.scanUntilKey = "2026-07-01"
        var parent = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 100,
            days: ["2026-04-10": ["gpt-5.5": [1, 0, 0]]])
        parent.sessionId = "parent-session"
        var unrelated = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 100,
            days: ["2026-04-11": ["gpt-5.5": [1, 0, 0]]])
        unrelated.sessionId = "unrelated-session"
        var child = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 100,
            days: ["2026-06-20": ["gpt-5.5": [1, 0, 0]]])
        child.forkedFromId = "parent-session"
        cache.files = [
            "/sessions/parent.jsonl": parent,
            "/sessions/unrelated.jsonl": unrelated,
            "/sessions/child.jsonl": child,
        ]
        cache.days = [
            "2026-04-10": ["gpt-5.5": [1, 0, 0]],
            "2026-04-11": ["gpt-5.5": [1, 0, 0]],
            "2026-06-20": ["gpt-5.5": [1, 0, 0]],
        ]

        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111",
            maxCacheEntries: 2)

        let loaded = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111")
        #expect(loaded.files["/sessions/parent.jsonl"] != nil)
        #expect(loaded.files["/sessions/unrelated.jsonl"] == nil)
        #expect(loaded.files["/sessions/child.jsonl"] != nil)
        #expect(loaded.days["2026-04-10"]?["gpt-5.5"] == [1, 0, 0])
        #expect(loaded.days["2026-04-11"] == nil)
    }

    @Test
    func `save preserves out-of-window entries that are still resuming`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var cache = CostUsageCache()
        cache.scanSinceKey = "2026-06-01"
        cache.scanUntilKey = "2026-07-01"
        var incomplete = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 100,
            days: ["2026-04-10": ["gpt-5.5": [1, 0, 0]]])
        incomplete.codexScanComplete = false
        var bufferedForkRetry = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 100,
            days: ["2026-04-11": ["gpt-5.5": [1, 0, 0]]])
        bufferedForkRetry.codexBufferedSubagentLines = [
            CostUsageScanner.CodexBufferedFastLine(
                lineIndex: 0,
                ordinal: nil,
                line: .taskStarted(turnID: nil)),
        ]
        var completedWithScanID = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 100,
            days: ["2026-04-13": ["gpt-5.5": [1, 0, 0]]])
        completedWithScanID.codexScanFileId = "scan-id"
        completedWithScanID.codexScanComplete = true
        let settled = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 100,
            days: ["2026-04-12": ["gpt-5.5": [1, 0, 0]]])
        cache.files = [
            "/sessions/incomplete.jsonl": incomplete,
            "/sessions/buffered-fork-retry.jsonl": bufferedForkRetry,
            "/sessions/completed-with-scan-id.jsonl": completedWithScanID,
            "/sessions/settled.jsonl": settled,
        ]
        cache.days = [
            "2026-04-10": ["gpt-5.5": [1, 0, 0]],
            "2026-04-11": ["gpt-5.5": [1, 0, 0]],
            "2026-04-13": ["gpt-5.5": [1, 0, 0]],
            "2026-04-12": ["gpt-5.5": [1, 0, 0]],
        ]

        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111",
            maxCacheEntries: 3)

        let loaded = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111")
        #expect(loaded.files["/sessions/incomplete.jsonl"] != nil)
        #expect(loaded.files["/sessions/buffered-fork-retry.jsonl"] != nil)
        #expect(loaded.files["/sessions/completed-with-scan-id.jsonl"] == nil)
        #expect(loaded.files["/sessions/settled.jsonl"] == nil)
        #expect(loaded.days["2026-04-12"] == nil)
    }

    @Test
    func `save prunes against the requested window and narrows persisted coverage`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var cache = CostUsageCache()
        cache.scanSinceKey = "2026-01-01"
        cache.scanUntilKey = "2026-07-01"
        cache.days = [
            "2026-02-10": ["gpt-5.5": [1, 0, 0]],
            "2026-06-20": ["gpt-5.5": [2, 0, 0]],
            "2026-06-28": ["gpt-5.5": [3, 0, 0]],
        ]
        for (index, day) in ["2026-02-10", "2026-06-20", "2026-06-28"].enumerated() {
            cache.files["/sessions/\(day).jsonl"] = CostUsageFileUsage(
                mtimeUnixMs: Int64(index),
                size: 100,
                days: [day: ["gpt-5.5": [index + 1, 0, 0]]])
        }

        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111",
            requestedScanWindow: (sinceKey: "2026-06-01", untilKey: "2026-07-01"),
            maxCacheEntries: 2)

        let loaded = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111")
        #expect(Array(loaded.files.keys).sorted() == [
            "/sessions/2026-06-20.jsonl",
            "/sessions/2026-06-28.jsonl",
        ])
        #expect(loaded.days["2026-02-10"] == nil)
        #expect(loaded.scanSinceKey == "2026-06-01")
        #expect(loaded.scanUntilKey == "2026-07-01")
    }

    @Test
    func `save prunes when the candidate artifact crosses the byte budget in one refresh`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var cache = CostUsageCache()
        cache.scanSinceKey = "2026-06-01"
        cache.scanUntilKey = "2026-07-01"
        let inWindow = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 100,
            days: ["2026-06-20": ["gpt-5.5": [1, 0, 0]]])
        var staleWithDetail = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 100,
            days: ["2026-04-10": ["gpt-5.5": [1, 0, 0]]])
        let snapshots = (0..<400).map { index in
            CostUsageCodexTokenSnapshot(
                timestamp: "2026-04-10T00:00:0\(index % 10)Z",
                last: nil,
                total: CostUsageCodexTotals(input: index, cached: 0, output: 0))
        }
        staleWithDetail.codexTokenSnapshots = snapshots
        cache.files = [
            "/sessions/in-window.jsonl": inWindow,
            "/sessions/stale-with-detail.jsonl": staleWithDetail,
        ]
        cache.days = [
            "2026-06-20": ["gpt-5.5": [1, 0, 0]],
            "2026-04-10": ["gpt-5.5": [1, 0, 0]],
        ]

        // The entry count is within budget and no previous artifact exists, but the
        // candidate payload exceeds the tiny byte budget; pruning must still happen.
        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111",
            requestedScanWindow: (sinceKey: "2026-06-01", untilKey: "2026-07-01"),
            maxCacheBytes: 1024,
            maxCacheEntries: 100)

        let loaded = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111")
        #expect(Array(loaded.files.keys) == ["/sessions/in-window.jsonl"])
        #expect(loaded.days["2026-04-10"] == nil)
        #expect(loaded.days["2026-06-20"]?["gpt-5.5"] == [1, 0, 0])
    }

    @Test
    func `load cap applies only to codex`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = CostUsageCacheIO.cacheFileURL(provider: .claude, cacheRoot: root)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        var payload = Data(
            #"{"version":1,"lastScanUnixMs":999,"files":{},"days":{}}"#.utf8)
        payload.append(Data(repeating: 0x20, count: 2048))
        try payload.write(to: url)

        // The load cap guards Codex's bounded-rebuild path only; Claude/Vertex caches are
        // not pruned on save, so rejecting them would cause a rebuild loop.
        let loaded = CostUsageCacheIO.load(
            provider: .claude,
            cacheRoot: root,
            maxCacheBytes: 1024)

        #expect(loaded.lastScanUnixMs == 999)
    }

    @Test
    func `save drops stale parents referenced only by stale children`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var cache = CostUsageCache()
        cache.scanSinceKey = "2026-06-01"
        cache.scanUntilKey = "2026-07-01"
        var parent = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 100,
            days: ["2026-04-10": ["gpt-5.5": [1, 0, 0]]])
        parent.sessionId = "parent-session"
        var staleChild = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 100,
            days: ["2026-04-11": ["gpt-5.5": [1, 0, 0]]])
        staleChild.sessionId = "child-session"
        staleChild.forkedFromId = "parent-session"
        cache.files = [
            "/sessions/parent.jsonl": parent,
            "/sessions/stale-child.jsonl": staleChild,
        ]
        cache.days = [
            "2026-04-10": ["gpt-5.5": [1, 0, 0]],
            "2026-04-11": ["gpt-5.5": [1, 0, 0]],
        ]

        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111",
            maxCacheEntries: 1)

        let loaded = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111")
        #expect(loaded.files.isEmpty)
        #expect(loaded.days.isEmpty)
    }

    @Test
    func `save retains recently active zero-day session entries`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = 2026
        components.month = 6
        components.day = 25
        components.hour = 12
        let activeMtime = Int64(
            (calendar.date(from: components) ?? Date()).timeIntervalSince1970 * 1000)

        var cache = CostUsageCache()
        cache.scanSinceKey = "2026-06-01"
        cache.scanUntilKey = "2026-07-01"
        var activeZeroDay = CostUsageFileUsage(
            mtimeUnixMs: activeMtime,
            size: 100,
            days: ["2026-04-10": ["gpt-5.5": [1, 0, 0]]])
        activeZeroDay.sessionId = "active-session"
        var inactive = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 100,
            days: ["2026-04-11": ["gpt-5.5": [1, 0, 0]]])
        inactive.sessionId = "inactive-session"
        cache.files = [
            "/sessions/active-zero-day.jsonl": activeZeroDay,
            "/sessions/inactive.jsonl": inactive,
        ]
        cache.days = [
            "2026-04-10": ["gpt-5.5": [1, 0, 0]],
            "2026-04-11": ["gpt-5.5": [1, 0, 0]],
        ]

        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111",
            maxCacheEntries: 1)

        let loaded = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111")
        #expect(loaded.files["/sessions/active-zero-day.jsonl"] != nil)
        #expect(loaded.files["/sessions/inactive.jsonl"] == nil)
        #expect(loaded.days["2026-04-10"]?["gpt-5.5"] == [1, 0, 0])
    }

    @Test
    func `save drops oldest in-window entries when the window corpus exceeds the byte budget`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var cache = CostUsageCache()
        cache.scanSinceKey = "2026-06-01"
        cache.scanUntilKey = "2026-07-01"
        let snapshots = (0..<300).map { index in
            CostUsageCodexTokenSnapshot(
                timestamp: "2026-06-0\(index % 9)T00:00:0\(index % 10)Z",
                last: nil,
                total: CostUsageCodexTotals(input: index, cached: 0, output: 0))
        }
        var older = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 100,
            days: ["2026-06-05": ["gpt-5.5": [1, 0, 0]]])
        older.codexTokenSnapshots = snapshots
        var recent = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 100,
            days: ["2026-06-28": ["gpt-5.5": [1, 0, 0]]])
        recent.codexTokenSnapshots = snapshots
        cache.files = [
            "/sessions/older.jsonl": older,
            "/sessions/recent.jsonl": recent,
        ]
        cache.days = [
            "2026-06-05": ["gpt-5.5": [1, 0, 0]],
            "2026-06-28": ["gpt-5.5": [1, 0, 0]],
        ]

        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111",
            requestedScanWindow: (sinceKey: "2026-06-01", untilKey: "2026-07-01"),
            maxCacheBytes: 30000,
            maxCacheEntries: 100)

        let loaded = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111")
        #expect(loaded.files["/sessions/older.jsonl"] == nil)
        #expect(loaded.files["/sessions/recent.jsonl"] != nil)
        #expect(loaded.days["2026-06-05"] == nil)
        #expect(loaded.days["2026-06-28"]?["gpt-5.5"] == [1, 0, 0])
    }

    @Test
    func `save marks trimmed caches as needing catch up`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var cache = CostUsageCache()
        cache.scanSinceKey = "2026-06-01"
        cache.scanUntilKey = "2026-07-01"
        cache.lastScanUnixMs = 123_456
        let snapshots = (0..<300).map { index in
            CostUsageCodexTokenSnapshot(
                timestamp: "2026-06-0\(index % 9)T00:00:0\(index % 10)Z",
                last: nil,
                total: CostUsageCodexTotals(input: index, cached: 0, output: 0))
        }
        var older = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 100,
            days: ["2026-06-05": ["gpt-5.5": [1, 0, 0]]])
        older.codexTokenSnapshots = snapshots
        var recent = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 100,
            days: ["2026-06-28": ["gpt-5.5": [1, 0, 0]]])
        recent.codexTokenSnapshots = snapshots
        cache.files = [
            "/sessions/older.jsonl": older,
            "/sessions/recent.jsonl": recent,
        ]
        cache.days = [
            "2026-06-05": ["gpt-5.5": [1, 0, 0]],
            "2026-06-28": ["gpt-5.5": [1, 0, 0]],
            "2026-05-31": ["gpt-5.5": [1, 0, 0]],
            "2026-07-02": ["gpt-5.5": [1, 0, 0]],
        ]

        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111",
            requestedScanWindow: (sinceKey: "2026-06-01", untilKey: "2026-07-01"),
            reportWindow: (sinceKey: "2026-06-01", untilKey: "2026-07-01"),
            maxCacheBytes: 30000,
            maxCacheEntries: 100)

        let loaded = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111")
        #expect(loaded.codexScanCatchUpPending == true)
        #expect(loaded.lastScanUnixMs == 0)
        #expect(loaded.codexPreviousReport != nil)
        #expect(loaded.codexPreviousReport?.data.contains { $0.date == "2026-06-05" } == true)
        #expect(loaded.codexPreviousReport?.data.contains { $0.date == "2026-06-28" } == true)
        #expect(loaded.codexPreviousReport?.data.contains { $0.date == "2026-05-31" } == false)
        #expect(loaded.codexPreviousReport?.data.contains { $0.date == "2026-07-02" } == false)
        #expect(loaded.codexPreviousReport?.scanSinceKey == "2026-06-01")
        #expect(loaded.codexPreviousReport?.scanUntilKey == "2026-07-01")
    }

    @Test
    func `save prunes discovery records with removed sessions`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var cache = CostUsageCache()
        cache.scanSinceKey = "2026-06-01"
        cache.scanUntilKey = "2026-07-01"
        var stale = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 100,
            days: ["2026-04-10": ["gpt-5.5": [1, 0, 0]]])
        stale.sessionId = "stale-session"
        var inWindow = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 100,
            days: ["2026-06-20": ["gpt-5.5": [1, 0, 0]]])
        inWindow.sessionId = "live-session"
        cache.files = [
            "/sessions/stale.jsonl": stale,
            "/sessions/in-window.jsonl": inWindow,
        ]
        cache.days = [
            "2026-04-10": ["gpt-5.5": [1, 0, 0]],
            "2026-06-20": ["gpt-5.5": [1, 0, 0]],
        ]
        cache.codexSessionDiscovery = CostUsageCodexSessionDiscovery(
            roots: ["/sessions"],
            generation: nil,
            directoryStamps: [:],
            directoryPaths: [],
            nextDirectoryIndex: 0,
            filePaths: ["/sessions/stale.jsonl", "/sessions/in-window.jsonl"],
            nextFileIndex: 0,
            fileStamps: [
                "/sessions/stale.jsonl": .init(mtimeUnixMs: 1, size: 100, fileId: nil),
                "/sessions/in-window.jsonl": .init(mtimeUnixMs: 1, size: 100, fileId: nil),
            ],
            headScan: nil,
            filePathBySessionId: [
                "stale-session": "/sessions/stale.jsonl",
                "live-session": "/sessions/in-window.jsonl",
            ],
            missingSessionIds: ["stale-session"],
            pendingSessionIds: [],
            validationDirectoryIndex: 0,
            isComplete: true)

        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111",
            requestedScanWindow: (sinceKey: "2026-06-01", untilKey: "2026-07-01"),
            maxCacheEntries: 1)

        let loaded = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111")
        let discovery = try #require(loaded.codexSessionDiscovery)
        #expect(discovery.filePaths == ["/sessions/in-window.jsonl"])
        #expect(discovery.fileStamps["/sessions/stale.jsonl"] == nil)
        #expect(discovery.filePathBySessionId["stale-session"] == nil)
        #expect(discovery.filePathBySessionId["live-session"] != nil)
        #expect(discovery.missingSessionIds == [])
        #expect(discovery.isComplete == false)
        #expect(discovery.nextFileIndex == 0)
        #expect(discovery.nextDirectoryIndex == 0)
    }

    @Test
    func `save strips detail from a sole oversized in-window entry`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var cache = CostUsageCache()
        cache.scanSinceKey = "2026-06-01"
        cache.scanUntilKey = "2026-07-01"
        var huge = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 1_000_000,
            days: ["2026-06-20": ["gpt-5.5": [1, 0, 0]]])
        huge.sessionId = "huge-session"
        huge.parsedBytes = 1_000_000
        huge.codexRows = [
            CostUsageScanner.CodexUsageRow(
                day: "2026-06-20",
                model: "gpt-5.5",
                turnID: "turn",
                eventIndex: 1,
                input: 10,
                cached: 2,
                output: 4,
                reasoning: nil),
        ]
        huge.codexTokenSnapshots = (0..<1000).map { index in
            CostUsageCodexTokenSnapshot(
                timestamp: "2026-06-20T00:00:0\(index % 10)Z",
                last: nil,
                total: CostUsageCodexTotals(input: index, cached: 0, output: 0))
        }
        cache.files = ["/sessions/huge.jsonl": huge]
        cache.days = ["2026-06-20": ["gpt-5.5": [1, 0, 0]]]

        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111",
            requestedScanWindow: (sinceKey: "2026-06-01", untilKey: "2026-07-01"),
            maxCacheBytes: 30000,
            maxCacheEntries: 100)

        let loaded = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111")
        let survivor = try #require(loaded.files["/sessions/huge.jsonl"])
        #expect(survivor.codexTokenSnapshots == nil)
        #expect(survivor.codexRows == nil)
        #expect(survivor.parsedBytes == 0)
        #expect(survivor.codexScanComplete == false)
        #expect(survivor.codexScanFileId == nil)
        #expect(survivor.days["2026-06-20"]?["gpt-5.5"] == [1, 0, 0])
        #expect(loaded.codexScanCatchUpPending == true)
    }

    @Test
    func `save compacts a protected fork parent that alone exceeds the budget`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var cache = CostUsageCache()
        cache.scanSinceKey = "2026-06-01"
        cache.scanUntilKey = "2026-07-01"
        var parent = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 1_000_000,
            days: ["2026-06-10": ["gpt-5.5": [1, 0, 0]]])
        parent.sessionId = "parent-session"
        parent.parsedBytes = 1_000_000
        parent.codexTokenSnapshots = (0..<1000).map { index in
            CostUsageCodexTokenSnapshot(
                timestamp: "2026-06-10T00:00:0\(index % 10)Z",
                last: nil,
                total: CostUsageCodexTotals(input: index, cached: 0, output: 0))
        }
        var child = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 100,
            days: ["2026-06-28": ["gpt-5.5": [1, 0, 0]]])
        child.sessionId = "child-session"
        child.forkedFromId = "parent-session"
        child.codexScanComplete = false
        cache.files = [
            "/sessions/parent.jsonl": parent,
            "/sessions/child.jsonl": child,
        ]
        cache.days = [
            "2026-06-10": ["gpt-5.5": [1, 0, 0]],
            "2026-06-28": ["gpt-5.5": [1, 0, 0]],
        ]

        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111",
            requestedScanWindow: (sinceKey: "2026-06-01", untilKey: "2026-07-01"),
            maxCacheBytes: 30000,
            maxCacheEntries: 100)

        let loaded = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111")
        let compacted = try #require(loaded.files["/sessions/parent.jsonl"])
        #expect(compacted.codexTokenSnapshots == nil)
        #expect(compacted.parsedBytes == 0)
        #expect(compacted.codexScanComplete == false)
        #expect(loaded.files["/sessions/child.jsonl"] != nil)
        #expect(loaded.codexScanCatchUpPending == true)
    }

    @Test
    func `save does not protect lineage only fork parents`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var cache = CostUsageCache()
        cache.scanSinceKey = "2026-06-01"
        cache.scanUntilKey = "2026-07-01"
        var parent = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 1_000_000,
            days: ["2026-04-10": ["gpt-5.5": [1, 0, 0]]])
        parent.sessionId = "parent-session"
        parent.codexTokenSnapshots = (0..<1000).map { index in
            CostUsageCodexTokenSnapshot(
                timestamp: "2026-04-10T00:00:0\(index % 10)Z",
                last: nil,
                total: CostUsageCodexTotals(input: index, cached: 0, output: 0))
        }
        var lineageChild = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 100,
            days: ["2026-06-28": ["gpt-5.5": [1, 0, 0]]])
        lineageChild.sessionId = "lineage-child"
        lineageChild.forkedFromId = "parent-session"
        lineageChild.forkBaselineDependencyKey = CostUsageScanner.codexForkDependencyNotRequiredKey
        cache.files = [
            "/sessions/parent.jsonl": parent,
            "/sessions/lineage-child.jsonl": lineageChild,
        ]
        cache.days = [
            "2026-04-10": ["gpt-5.5": [1, 0, 0]],
            "2026-06-28": ["gpt-5.5": [1, 0, 0]],
        ]

        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111",
            requestedScanWindow: (sinceKey: "2026-06-01", untilKey: "2026-07-01"),
            maxCacheEntries: 1)

        let loaded = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111")
        #expect(loaded.files["/sessions/parent.jsonl"] == nil)
        #expect(loaded.files["/sessions/lineage-child.jsonl"] != nil)
        #expect(loaded.days["2026-04-10"] == nil)
    }

    @Test
    func `save enforces the byte cap when the estimate underestimates the payload`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var cache = CostUsageCache()
        cache.scanSinceKey = "2026-06-01"
        cache.scanUntilKey = "2026-07-01"
        var entry = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 1_000_000,
            days: ["2026-06-20": ["gpt-5.5": [1, 0, 0]]])
        entry.sessionId = "big-session"
        entry.parsedBytes = 1_000_000
        let longTimestamp = "2026-06-20T00:00:00.000000000Z-\(String(repeating: "x", count: 80))"
        entry.codexTokenSnapshots = (0..<850).map { index in
            CostUsageCodexTokenSnapshot(
                timestamp: "\(longTimestamp)-\(index)",
                last: nil,
                total: CostUsageCodexTotals(input: index, cached: 0, output: 0))
        }
        cache.files = ["/sessions/big.jsonl": entry]
        cache.days = ["2026-06-20": ["gpt-5.5": [1, 0, 0]]]
        let maxCacheBytes = 115_000

        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111",
            requestedScanWindow: (sinceKey: "2026-06-01", untilKey: "2026-07-01"),
            maxCacheBytes: maxCacheBytes,
            maxCacheEntries: 100)

        let url = CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: root)
        let artifactBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        #expect(artifactBytes <= maxCacheBytes)
        let loaded = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111")
        #expect(loaded.files["/sessions/big.jsonl"]?.codexTokenSnapshots == nil)
        #expect(loaded.codexScanCatchUpPending == true)
        #expect(loaded.days["2026-06-20"]?["gpt-5.5"] == [1, 0, 0])
    }

    @Test
    func `save re-encodes after a forced prune removes out-of-window entries`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var cache = CostUsageCache()
        cache.scanSinceKey = "2026-06-01"
        cache.scanUntilKey = "2026-07-01"
        var stale = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 1_000_000,
            days: ["2026-04-10": ["gpt-5.5": [1, 0, 0]]])
        stale.sessionId = "stale-session"
        let longTimestamp = "2026-04-10T00:00:00.000000000Z-\(String(repeating: "x", count: 80))"
        stale.codexTokenSnapshots = (0..<850).map { index in
            CostUsageCodexTokenSnapshot(
                timestamp: "\(longTimestamp)-\(index)",
                last: nil,
                total: CostUsageCodexTotals(input: index, cached: 0, output: 0))
        }
        var inWindow = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 100,
            days: ["2026-06-20": ["gpt-5.5": [1, 0, 0]]])
        inWindow.sessionId = "live-session"
        cache.files = [
            "/sessions/stale.jsonl": stale,
            "/sessions/in-window.jsonl": inWindow,
        ]
        cache.days = [
            "2026-04-10": ["gpt-5.5": [1, 0, 0]],
            "2026-06-20": ["gpt-5.5": [1, 0, 0]],
        ]
        let maxCacheBytes = 115_000

        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111",
            requestedScanWindow: (sinceKey: "2026-06-01", untilKey: "2026-07-01"),
            maxCacheBytes: maxCacheBytes,
            maxCacheEntries: 100)

        let url = CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: root)
        let artifactBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        #expect(artifactBytes <= maxCacheBytes)
        let loaded = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111")
        #expect(loaded.files["/sessions/stale.jsonl"] == nil)
        #expect(loaded.files["/sessions/in-window.jsonl"] != nil)
        #expect(loaded.days["2026-04-10"] == nil)
    }

    @Test
    func `save rewinds active lookback body work when it keeps the artifact over budget`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var cache = CostUsageCache()
        cache.scanSinceKey = "2026-06-01"
        cache.scanUntilKey = "2026-07-01"
        var inWindow = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 100,
            days: ["2026-06-20": ["gpt-5.5": [1, 0, 0]]])
        inWindow.sessionId = "live-session"
        cache.files = ["/sessions/in-window.jsonl": inWindow]
        cache.days = ["2026-06-20": ["gpt-5.5": [1, 0, 0]]]
        cache.codexActiveLookbackState = CostUsageCodexActiveLookbackState(
            scanSinceKey: "2026-06-01",
            rootPaths: ["/sessions"],
            nextDayKeyByRoot: ["/sessions": "2026-06-02"],
            completedRootPaths: [],
            pendingFilePaths: (0..<3000).map { "/sessions/pending-\($0).jsonl" },
            legacyRecursivePendingRootPaths: ["/sessions/archive"])
        let maxCacheBytes = 30000

        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111",
            requestedScanWindow: (sinceKey: "2026-06-01", untilKey: "2026-07-01"),
            maxCacheBytes: maxCacheBytes,
            maxCacheEntries: 100)

        let loaded = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111")
        let lookback = try #require(loaded.codexActiveLookbackState)
        #expect(lookback.pendingFilePaths.isEmpty)
        #expect(lookback.completedRootPaths.isEmpty)
        #expect(lookback.nextDayKeyByRoot.isEmpty)
        #expect(lookback.legacyRecursivePendingRootPaths == ["/sessions", "/sessions/archive"])
        #expect(loaded.codexSessionDiscovery == nil)
        #expect(loaded.codexScanCatchUpPending == true)
        #expect(loaded.lastScanUnixMs == 0)
        #expect(loaded.files["/sessions/in-window.jsonl"] != nil)
    }

    @Test
    func `save compacts a dropped parent required by the kept survivor`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var cache = CostUsageCache()
        cache.scanSinceKey = "2026-06-01"
        cache.scanUntilKey = "2026-07-01"
        var parent = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 1_000_000,
            days: ["2026-06-05": ["gpt-5.5": [1, 0, 0]]])
        parent.sessionId = "parent-session"
        parent.parsedBytes = 1_000_000
        parent.codexTokenSnapshots = (0..<1000).map { index in
            CostUsageCodexTokenSnapshot(
                timestamp: "2026-06-05T00:00:0\(index % 10)Z",
                last: nil,
                total: CostUsageCodexTotals(input: index, cached: 0, output: 0))
        }
        var child = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 100,
            days: ["2026-06-28": ["gpt-5.5": [1, 0, 0]]])
        child.sessionId = "child-session"
        child.forkedFromId = "parent-session"
        cache.files = [
            "/sessions/parent.jsonl": parent,
            "/sessions/child.jsonl": child,
        ]
        cache.days = [
            "2026-06-05": ["gpt-5.5": [1, 0, 0]],
            "2026-06-28": ["gpt-5.5": [1, 0, 0]],
        ]

        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111",
            requestedScanWindow: (sinceKey: "2026-06-01", untilKey: "2026-07-01"),
            maxCacheBytes: 30000,
            maxCacheEntries: 100)

        let loaded = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111")
        let compacted = try #require(loaded.files["/sessions/parent.jsonl"])
        #expect(compacted.codexTokenSnapshots == nil)
        #expect(compacted.parsedBytes == 0)
        #expect(compacted.codexScanComplete == false)
        #expect(loaded.files["/sessions/child.jsonl"] != nil)
        #expect(loaded.codexScanCatchUpPending == true)
    }

    @Test
    func `save prunes orphaned discovery mappings when they keep the artifact over budget`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var cache = CostUsageCache()
        cache.scanSinceKey = "2026-06-01"
        cache.scanUntilKey = "2026-07-01"
        var inWindow = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 100,
            days: ["2026-06-20": ["gpt-5.5": [1, 0, 0]]])
        inWindow.sessionId = "live-session"
        cache.files = ["/sessions/in-window.jsonl": inWindow]
        cache.days = ["2026-06-20": ["gpt-5.5": [1, 0, 0]]]
        cache.codexSessionDiscovery = CostUsageCodexSessionDiscovery(
            roots: ["/sessions"],
            generation: nil,
            directoryStamps: [:],
            directoryPaths: [],
            nextDirectoryIndex: 0,
            filePaths: ["/sessions/in-window.jsonl"],
            nextFileIndex: 0,
            fileStamps: ["/sessions/in-window.jsonl": .init(mtimeUnixMs: 1, size: 100, fileId: nil)],
            headScan: nil,
            filePathBySessionId: Dictionary(
                uniqueKeysWithValues: (0..<3000).map { index in
                    ("orphan-\(index)", "/sessions/deleted-\(index).jsonl")
                }),
            missingSessionIds: [],
            pendingSessionIds: [],
            validationDirectoryIndex: 0,
            isComplete: true)
        let maxCacheBytes = 30000

        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111",
            requestedScanWindow: (sinceKey: "2026-06-01", untilKey: "2026-07-01"),
            maxCacheBytes: maxCacheBytes,
            maxCacheEntries: 100)

        let url = CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: root)
        let artifactBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        #expect(artifactBytes <= maxCacheBytes)
        let loaded = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111")
        #expect(loaded.codexSessionDiscovery?.filePathBySessionId.isEmpty == true)
        #expect(loaded.files["/sessions/in-window.jsonl"] != nil)
    }

    @Test
    func `save shares discovery id capacity across missing and pending lists`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var cache = CostUsageCache()
        cache.scanSinceKey = "2026-06-01"
        cache.scanUntilKey = "2026-07-01"
        var inWindow = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 100,
            days: ["2026-06-20": ["gpt-5.5": [1, 0, 0]]])
        inWindow.sessionId = "live-session"
        cache.files = ["/sessions/in-window.jsonl": inWindow]
        cache.days = ["2026-06-20": ["gpt-5.5": [1, 0, 0]]]
        cache.codexSessionDiscovery = CostUsageCodexSessionDiscovery(
            roots: ["/sessions"],
            generation: nil,
            directoryStamps: [:],
            directoryPaths: [],
            nextDirectoryIndex: 0,
            filePaths: ["/sessions/in-window.jsonl"],
            nextFileIndex: 0,
            fileStamps: ["/sessions/in-window.jsonl": .init(mtimeUnixMs: 1, size: 100, fileId: nil)],
            headScan: nil,
            filePathBySessionId: ["live-session": "/sessions/in-window.jsonl"],
            missingSessionIds: (0..<2000).map { "missing-\($0)" },
            pendingSessionIds: (0..<2000).map { "pending-\($0)" },
            validationDirectoryIndex: 0,
            isComplete: true)
        let maxCacheBytes = 30000

        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111",
            requestedScanWindow: (sinceKey: "2026-06-01", untilKey: "2026-07-01"),
            maxCacheBytes: maxCacheBytes,
            maxCacheEntries: 100)

        let loaded = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111")
        let discovery = try #require(loaded.codexSessionDiscovery)
        let combined = discovery.missingSessionIds.count + discovery.pendingSessionIds.count
        #expect(combined <= maxCacheBytes / 48)
        #expect(combined < 2000)
    }

    @Test
    func `save preserves an existing complete report across repeated trims`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var cache = CostUsageCache()
        cache.scanSinceKey = "2026-06-01"
        cache.scanUntilKey = "2026-07-01"
        var older = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 1_000_000,
            days: ["2026-06-05": ["gpt-5.5": [1, 0, 0]]])
        older.sessionId = "older-session"
        older.codexTokenSnapshots = (0..<1000).map { index in
            CostUsageCodexTokenSnapshot(
                timestamp: "2026-06-05T00:00:0\(index % 10)Z",
                last: nil,
                total: CostUsageCodexTotals(input: index, cached: 0, output: 0))
        }
        var recent = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 100,
            days: ["2026-06-28": ["gpt-5.5": [1, 0, 0]]])
        recent.sessionId = "recent-session"
        cache.files = [
            "/sessions/older.jsonl": older,
            "/sessions/recent.jsonl": recent,
        ]
        cache.days = [
            "2026-06-05": ["gpt-5.5": [1, 0, 0]],
            "2026-06-28": ["gpt-5.5": [1, 0, 0]],
        ]
        // Simulate an already pending catch-up pass with a complete previous report.
        cache.codexScanCatchUpPending = true
        cache.codexPreviousReport = CostUsageCodexPreviousReport(
            report: CostUsageDailyReport(data: [
                CostUsageDailyReport.Entry(
                    date: "2026-06-05",
                    inputTokens: 1,
                    outputTokens: 0,
                    totalTokens: 1,
                    costUSD: nil,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ], summary: nil),
            cache: cache)

        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111",
            requestedScanWindow: (sinceKey: "2026-06-01", untilKey: "2026-07-01"),
            maxCacheBytes: 30000,
            maxCacheEntries: 100)

        let loaded = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111")
        let preserved = try #require(loaded.codexPreviousReport)
        #expect(preserved.data.count == 1)
        #expect(preserved.data.first?.date == "2026-06-05")
        #expect(preserved.data.contains { $0.date == "2026-06-28" } == false)
    }

    @Test
    func `codex load cap keeps headroom over the save budget with a real save load round trip`() throws {
        // `save` bounds the artifact to `maxCacheFileBytes`; the load cap must stay above it
        // (with slack for enforcement overshoot) or every persisted artifact near the budget
        // would be refused and rebuilt on the next launch.
        #expect(CostUsageCacheIO.maxCacheLoadBytes > CostUsageCacheIO.maxCacheFileBytes)

        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: root)
        var cache = CostUsageCache()
        cache.scanSinceKey = "2026-06-01"
        cache.scanUntilKey = "2026-07-01"
        // A resuming entry cannot be pruned, trimmed, or stripped, so the encoded payload
        // stays above the save budget; the overshoot must still fit the load cap and the
        // artifact must remain readable instead of entering a rebuild loop.
        var resuming = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 100,
            days: ["2026-06-20": ["gpt-5.5": [1, 0, 0]]])
        resuming.codexScanComplete = false
        resuming.codexBufferedSubagentLines = (0..<20).map { index in
            CostUsageScanner.CodexBufferedFastLine(
                lineIndex: index,
                ordinal: nil,
                line: .taskStarted(turnID: "turn-\(index)-\(String(repeating: "x", count: 300))"))
        }
        cache.files = ["/sessions/resuming.jsonl": resuming]
        cache.days = ["2026-06-20": ["gpt-5.5": [1, 0, 0]]]

        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111",
            requestedScanWindow: (sinceKey: "2026-06-01", untilKey: "2026-07-01"),
            maxCacheBytes: 1024,
            maxCacheEntries: 100,
            maxCacheLoadBytes: 50000)

        let artifactBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        #expect(artifactBytes > 1024)
        #expect(artifactBytes <= 50000)

        let loaded = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111")
        #expect(loaded.files["/sessions/resuming.jsonl"]?.codexBufferedSubagentLines?.count == 20)
    }

    @Test
    func `catch up report honors a non-gregorian system calendar`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var calendar = Calendar(identifier: .buddhist)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

        var cache = CostUsageCache()
        cache.scanSinceKey = "2026-06-01"
        cache.scanUntilKey = "2026-07-01"
        var entry = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 1_000_000,
            days: ["2026-06-05": ["gpt-5.5": [1, 0, 0]]])
        entry.sessionId = "in-window-session"
        entry.codexTokenSnapshots = (0..<500).map { index in
            CostUsageCodexTokenSnapshot(
                timestamp: "2026-06-05T00:00:0\(index % 10)Z",
                last: nil,
                total: CostUsageCodexTotals(input: index, cached: 0, output: 0))
        }
        cache.files = ["/sessions/in-window.jsonl": entry]
        cache.days = ["2026-06-05": ["gpt-5.5": [1, 0, 0]]]

        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111",
            calendar: calendar,
            requestedScanWindow: (sinceKey: "2026-06-01", untilKey: "2026-07-01"),
            reportWindow: (sinceKey: "2026-06-01", untilKey: "2026-07-01"),
            maxCacheBytes: 30000,
            maxCacheEntries: 100)

        let loaded = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111")
        let previous = try #require(loaded.codexPreviousReport)
        #expect(previous.data.contains { $0.date == "2026-06-05" })
        #expect(previous.data.contains { $0.date == "1483-06-05" } == false)
    }

    @Test
    func `save preserves the published artifact when a candidate cannot fit the load cap`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: root)
        var published = CostUsageCache()
        published.scanSinceKey = "2026-06-01"
        published.scanUntilKey = "2026-07-01"
        published.days = ["2026-06-10": ["gpt-5.5": [7, 0, 0]]]
        CostUsageCacheIO.save(
            provider: .codex,
            cache: published,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111",
            requestedScanWindow: (sinceKey: "2026-06-01", untilKey: "2026-07-01"),
            maxCacheBytes: 1024 * 1024,
            maxCacheEntries: 100)
        let publishedData = try Data(contentsOf: url)

        var cache = CostUsageCache()
        cache.scanSinceKey = "2026-06-01"
        cache.scanUntilKey = "2026-07-01"
        // An in-window entry that is still resuming keeps its buffered fork-retry lines:
        // pruning, trimming, and detail stripping all skip it, so the payload cannot shrink.
        var resuming = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 100,
            days: ["2026-06-20": ["gpt-5.5": [1, 0, 0]]])
        resuming.codexScanComplete = false
        resuming.codexBufferedSubagentLines = (0..<200).map { index in
            CostUsageScanner.CodexBufferedFastLine(
                lineIndex: index,
                ordinal: nil,
                line: .taskStarted(turnID: "turn-\(index)-\(String(repeating: "x", count: 600))"))
        }
        cache.files = ["/sessions/resuming.jsonl": resuming]
        cache.days = ["2026-06-20": ["gpt-5.5": [1, 0, 0]]]

        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111",
            requestedScanWindow: (sinceKey: "2026-06-01", untilKey: "2026-07-01"),
            maxCacheBytes: 1024,
            maxCacheEntries: 100,
            maxCacheLoadBytes: 50000)

        // Refusing this writer's oversized candidate must not delete a valid artifact that a
        // concurrent process may already have published.
        #expect(try Data(contentsOf: url) == publishedData)
        let loaded = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: root,
            producerKey: "codex:cu:p1111111111111111")
        #expect(loaded.days == published.days)
    }

    private func makeTemporaryCacheRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-cost-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
