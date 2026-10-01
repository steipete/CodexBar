import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageClaudeFragmentTests {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let strings = [
        "", "caf\u{e9}", "cafe\u{301}", "e\u{301}z", "z", "\u{e000}", "😀", "a10", "a2", "A", "a",
        "quote\"slash/\\\n\t\u{0}", "files", "{\"files\":{}}", "👩🏽‍💻",
    ]

    private func file(_ number: Int) -> CostUsageFileUsage {
        let string = Self.strings[number % Self.strings.count]
        let row = CostUsageScanner.ClaudeUsageRow(
            dayKey: string,
            model: string,
            sessionId: number.isMultiple(of: 2) ? nil : string,
            messageId: string,
            requestId: number.isMultiple(of: 3) ? nil : string,
            timestampUnixMs: number.isMultiple(of: 2) ? nil : Int64.min + Int64(number),
            isSidechain: number.isMultiple(of: 2),
            pathRole: number.isMultiple(of: 2) ? .parent : .subagent,
            input: Int.max - number,
            cacheRead: -number,
            cacheCreate: number,
            cacheCreate1h: number,
            output: number,
            costNanos: -number,
            costPriced: number.isMultiple(of: 3) ? nil : false,
            isIncomplete: number.isMultiple(of: 2) ? nil : true)
        return CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 1,
            days: [string: [string: [number, -number, Int.max]]],
            parsedBytes: 1,
            lastModel: string,
            sessionId: string,
            claudeRows: number.isMultiple(of: 7) ? nil : [row])
    }

    @Test(arguments: [UInt64(7), 42, 20_260_930])
    func `randomized incremental encodes are byte identical`(seed: UInt64) throws {
        let memo = CostUsageClaudeFragments()
        let url = URL(fileURLWithPath: "/synthetic/\(seed).json")
        var cache = CostUsageClaudeCache()
        var previous: [Data: Data] = [:]
        var random = seed
        for step in 0..<60 {
            random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let index = Int(random % UInt64(Self.strings.count))
            let path = Self.strings[index]
            if step.isMultiple(of: 11) {
                cache.usage.files = [:]
            } else if step.isMultiple(of: 4) {
                cache.usage.files.removeValue(forKey: path)
            } else {
                cache.usage.files[path] = self.file(index + step)
            }
            cache.usage.days = [:]
            if !step.isMultiple(of: 2) {
                cache.usage.days["files"] = [:]
                cache.usage.days[path] = [path: [-step]]
            }
            cache.usage.roots = step.isMultiple(of: 3) ? nil : [path: Int64.min]
            cache.sourceFileIDs = [path: Self.strings[(index + 1) % Self.strings.count]]
            let numbers = [1e-200, -1.25, 1e200, -0.0, Double.leastNonzeroMagnitude]
            let report = CostUsageDailyReport(
                data: [.init(
                    date: path,
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: nil,
                    costUSD: numbers[step % numbers.count],
                    modelsUsed: nil,
                    modelBreakdowns: nil)],
                summary: nil)
            cache.usage.codexPreviousReport = step.isMultiple(of: 2) ? nil : CostUsageCodexPreviousReport(
                report: report, cache: cache.usage, reportSinceKey: path, reportUntilKey: path)
            var current: [Data: Data] = [:]
            for (key, file) in cache.usage.files {
                try current[self.encoder.encode(key)] = try self.encoder.encode(file)
            }
            let changed = current.filter { previous[$0.key] != $0.value }.count
            let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
            let actual = try CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
                try memo.encode(cache, at: url, encoder: self.encoder)
            }
            #expect(try actual == (self.encoder.encode(cache)), "seed=\(seed) step=\(step)")
            #expect(recorder.snapshot().fragmentEncodes == changed)
            #expect(recorder.snapshot().fragmentFallbacks == 0)
            previous = current
        }
    }

    @Test
    func `equal metadata and canonically equal strings never hide byte changes`() throws {
        let memo = CostUsageClaudeFragments()
        let url = URL(fileURLWithPath: "/synthetic/unicode.json")
        var cache = CostUsageClaudeCache()
        cache.usage.files["caf\u{e9}"] = self.file(1)
        _ = try memo.encode(cache, at: url, encoder: self.encoder)
        let initial = try self.encoder.encode(cache)
        // Round-trip replacement reaches every row string and metadata without changing counts or stat fields.
        let source = try #require(String(data: initial, encoding: .utf8))
        cache = try JSONDecoder().decode(
            CostUsageClaudeCache.self,
            from: Data(source.replacingOccurrences(of: "caf\u{e9}", with: "cafe\u{301}").utf8))
        let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
        let actual = try CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
            try memo.encode(cache, at: url, encoder: self.encoder)
        }
        #expect(actual != initial)
        #expect(try actual == (self.encoder.encode(cache)))
        #expect(recorder.snapshot().fragmentEncodes == 1)
        // Independently change each compact row field while all metadata and counts remain identical.
        for field in ["d", "m", "s", "i", "r", "t", "b", "p", "in", "cr", "cc", "ch", "out", "c", "priced", "partial"] {
            var object = try #require(JSONSerialization.jsonObject(with: self.encoder.encode(cache)) as? [String: Any])
            var files = try #require(object["files"] as? [String: [String: Any]])
            let key = try #require(files.keys.first)
            var file = try #require(files[key])
            var rows = try #require(file["claudeRows"] as? [[String: Any]])
            switch field {
            case "d", "m", "s", "i", "r": rows[0][field] = "caf\u{e9}"
            case "b", "priced", "partial": rows[0][field] = !(rows[0][field] as? Bool ?? false)
            case "p": rows[0][field] = "parent"
            default: rows[0][field] = 42
            }
            file["claudeRows"] = rows
            files[key] = file
            object["files"] = files
            cache = try JSONDecoder().decode(
                CostUsageClaudeCache.self,
                from: JSONSerialization.data(withJSONObject: object))
            let change = CostUsageScanner.ClaudeScanWorkRecorder()
            let data = try CostUsageScanner.withClaudeScanWorkRecorderForTesting(change) {
                try memo.encode(cache, at: url, encoder: self.encoder)
            }
            #expect(try data == (self.encoder.encode(cache)))
            #expect(change.snapshot().fragmentEncodes == 1, "field=\(field)")
        }
    }

    @Test
    func `encoder supplies adversarial key order and escaping`() throws {
        let memo = CostUsageClaudeFragments()
        var cache = CostUsageClaudeCache()
        for (index, key) in Self.strings.enumerated() {
            cache.usage.files[key] = self.file(index)
        }
        let keys = ["é", "e\u{301}z", "z"]
        #expect(keys.sorted() != keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
        #expect(try memo.encode(cache, at: URL(fileURLWithPath: "/synthetic/order"), encoder: self.encoder)
            == self.encoder.encode(cache))
    }

    @Test
    func `URL isolation and bounded eviction never reuse another cache`() throws {
        for limit in [0, 1024 * 1024] {
            let memo = CostUsageClaudeFragments(byteLimit: limit)
            var cache = CostUsageClaudeCache()
            cache.usage.files["file"] = self.file(1)
            for index in 0..<5 {
                _ = try memo.encode(cache, at: URL(fileURLWithPath: "/synthetic/\(index)"), encoder: self.encoder)
            }
            let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
            try CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
                for index in [0, 0] {
                    _ = try memo.encode(cache, at: URL(fileURLWithPath: "/synthetic/\(index)"), encoder: self.encoder)
                }
            }
            #expect(recorder.snapshot().fragmentEncodes == (limit == 0 ? 2 : 1))
        }
    }

    @Test
    func `unsupported encoding format falls back exactly`() throws {
        let memo = CostUsageClaudeFragments()
        var cache = CostUsageClaudeCache()
        cache.usage.files["file"] = self.file(1)
        self.encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
        let actual = try CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
            try memo.encode(cache, at: URL(fileURLWithPath: "/synthetic/fallback"), encoder: self.encoder)
        }
        #expect(try actual == (self.encoder.encode(cache)))
        #expect(recorder.snapshot().fragmentFallbacks == 1)
        #expect(recorder.snapshot().fragmentEncodes == 0)
    }

    @Test
    func `save encodes only three changed files and added files`() throws {
        try CostUsageClaudeFragments.$shared.withValue(CostUsageClaudeFragments()) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            var cache = CostUsageClaudeCache()
            for index in 0..<100 {
                cache.usage.files["file-\(index)"] = self.file(index)
            }
            _ = try CostUsageClaudeCacheIO.save(provider: .claude, cache: cache, cacheRoot: root)
            for index in 0..<3 {
                cache.usage.files["file-\(index)"]?.mtimeUnixMs += 1
            }
            cache.usage.files.removeValue(forKey: "file-50")
            cache.usage.files["added"] = self.file(1)
            let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
            try CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
                _ = try CostUsageClaudeCacheIO.save(provider: .claude, cache: cache, cacheRoot: root)
            }
            #expect(recorder.snapshot().fragmentEncodes == 4)
            #expect(recorder.snapshot().fragmentFallbacks == 0)
            cache.usage.version = 4
            cache.usage.timeZoneIdentifier = Calendar.current.timeZone.identifier
            let url = CostUsageClaudeCacheIO.cacheFileURL(provider: .claude, cacheRoot: root)
            #expect(try Data(contentsOf: url) == self.encoder.encode(cache))
        }
    }
}
