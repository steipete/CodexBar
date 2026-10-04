import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageClaudeFragmentTests {
    private final class LockedValue<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ value: Value) { self.value = value }

        func withLock<Result>(_ operation: (inout Value) -> Result) -> Result {
            self.lock.withLock { operation(&self.value) }
        }
    }

    private final class Directory {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        deinit { try? FileManager.default.removeItem(at: self.url) }
    }

    private let directory = Directory()

    private func encode(_ memo: CostUsageClaudeFragments, _ cache: CostUsageClaudeCache, at url: URL) throws -> Data {
        try FileManager.default.createDirectory(at: self.directory.url, withIntermediateDirectories: true)
        let target = self.directory.url.appendingPathComponent(url.lastPathComponent)
            .standardizedFileURL.resolvingSymlinksInPath()
        let temporary = target.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        let stamp = try memo.write(
            cache,
            at: target,
            encoder: self.encoder,
            output: { data in
                if let data { try handle.write(contentsOf: data) } else {
                    try handle.truncate(atOffset: 0)
                    try handle.seek(toOffset: 0)
                }
            },
            commit: {
                try handle.synchronize()
                let stamp = CostUsageClaudeFileStamp.read(at: temporary)
                #expect(rename(temporary.path, target.path) == 0)
                return stamp
            })
        #expect(stamp != nil)
        return try Data(contentsOf: target)
    }

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
                try self.encode(memo, cache, at: url)
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
        _ = try self.encode(memo, cache, at: url)
        let initial = try self.encoder.encode(cache)
        // Round-trip replacement reaches every row string and metadata without changing counts or stat fields.
        let source = try #require(String(data: initial, encoding: .utf8))
        cache = try JSONDecoder().decode(
            CostUsageClaudeCache.self,
            from: Data(source.replacingOccurrences(of: "caf\u{e9}", with: "cafe\u{301}").utf8))
        let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
        let actual = try CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
            try self.encode(memo, cache, at: url)
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
                try self.encode(memo, cache, at: url)
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
        #expect(try self.encode(memo, cache, at: URL(fileURLWithPath: "/synthetic/order"))
            == self.encoder.encode(cache))
    }

    @Test
    func `URL isolation and bounded eviction never reuse another cache`() throws {
        for limit in [0, 1024 * 1024] {
            let memo = CostUsageClaudeFragments(byteLimit: limit)
            var cache = CostUsageClaudeCache()
            cache.usage.files["file"] = self.file(1)
            for index in 0..<5 {
                _ = try self.encode(memo, cache, at: URL(fileURLWithPath: "/synthetic/\(index)"))
            }
            let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
            try CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
                for index in [0, 0] {
                    _ = try self.encode(memo, cache, at: URL(fileURLWithPath: "/synthetic/\(index)"))
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
            try self.encode(memo, cache, at: URL(fileURLWithPath: "/synthetic/fallback"))
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

    @Test
    func `saves retain locations and materialize only one encoded file`() throws {
        let memo = CostUsageClaudeFragments()
        var cache = CostUsageClaudeCache()
        for index in 0..<100 {
            var file = self.file(index)
            file.claudeRows = try Array(repeating: #require(self.file(1).claudeRows?[0]), count: index + 1)
            cache.usage.files["file-\(index)"] = file
        }
        let samples = LockedValue<[(Int, Int)]>([])
        let largest = try #require(cache.usage.files.values.map { try self.encoder.encode($0).count }.max())
        let url = URL(fileURLWithPath: "/synthetic/memory")
        let observer: @Sendable (Int, Int) -> Void = { bytes, templates in
            samples.withLock { $0.append((bytes, templates)) }
        }
        let data = try CostUsageClaudeFragments.$observeBytesForTesting.withValue(observer) {
            try self.encode(memo, cache, at: url)
        }
        let observed = samples.withLock { $0 }
        #expect(observed.count == 100)
        #expect(observed.map(\.0).max() == largest)
        var header = cache
        header.usage.files = [:]
        let templates = try self.encoder.encode(header).count + self.encoder.encode("files").count
            + self.encoder.encode(cache.usage.files.mapValues { _ in 0 }).count
        #expect(observed.allSatisfy { $0.1 == templates && $0.0 + $0.1 <= largest + templates })
        // Inspect actual retained state; the old Fragment.data contributes every encoded value here.
        let entries = try #require(Mirror(reflecting: memo).children.first { $0.label == "entries" })
        let retained = Mirror(reflecting: entries.value).children.reduce(0) { bytes, entry in
            let files = Mirror(reflecting: entry.value).children.first { $0.label == "files" }!
            return bytes + Mirror(reflecting: files.value).children.reduce(0) { bytes, pair in
                let fragment = Array(Mirror(reflecting: pair.value).children)[1].value
                return bytes + Mirror(reflecting: fragment).children.reduce(0) { bytes, field in
                    bytes + (field.label == "metadata" ? 0 : (field.value as? Data)?.count ?? 0)
                }
            }
        }
        #expect(retained == 0)
        #expect(data.count > largest * 10)
        try cache.usage.files["file-0"]?.claudeRows?.append(#require(self.file(1).claudeRows?[0]))
        let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
        let appended = try CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
            try self.encode(memo, cache, at: url)
        }
        #expect(recorder.snapshot().fragmentEncodes == 1)
        #expect(try appended == self.encoder.encode(cache))
        memo.evict(at: self.directory.url.appendingPathComponent(url.lastPathComponent))
        let evicted = CostUsageScanner.ClaudeScanWorkRecorder()
        try CostUsageScanner.withClaudeScanWorkRecorderForTesting(evicted) {
            _ = try self.encode(memo, cache, at: url)
        }
        #expect(evicted.snapshot().fragmentEncodes == 100)
        print("[fragment-memory] retainedEncodedBytes=\(retained) largestFile=\(largest) " +
            "templates=\(observed.first!.1) artifact=\(data.count) appendEncodes=1")
    }

    @Test(arguments: ["replace", "touch", "truncate"])
    func `external changes invalidate all recorded locations`(change: String) throws {
        let memo = CostUsageClaudeFragments()
        var cache = CostUsageClaudeCache()
        for index in 0..<3 {
            cache.usage.files["file-\(index)"] = self.file(index)
        }
        let url = URL(fileURLWithPath: "/synthetic/external")
        let original = try self.encode(memo, cache, at: url)
        let target = self.directory.url.appendingPathComponent(url.lastPathComponent)
        let before = try #require(CostUsageClaudeFileStamp.read(at: target))
        switch change {
        case "replace": try original.write(to: target, options: .atomic)
        case "touch":
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: Double(before.modifiedSeconds) + 10)],
                ofItemAtPath: target.path)
        default: try Data(original.prefix(original.count / 2)).write(to: target)
        }
        #expect(CostUsageClaudeFileStamp.read(at: target) != before)
        let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
        let actual = try CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
            try self.encode(memo, cache, at: url)
        }
        #expect(actual == original)
        #expect(recorder.snapshot().fragmentEncodes == 3)
        #expect(recorder.snapshot().fragmentFallbacks == 0)
    }

    @Test
    func `decoded cache and persistence identity release their mapped input`() throws {
        var cache = CostUsageClaudeCache()
        cache.usage.version = 4
        cache.usage.timeZoneIdentifier = Calendar.current.timeZone.identifier
        cache.usage.files["file"] = self.file(1)
        let root = self.directory.url
        let url = CostUsageClaudeCacheIO.cacheFileURL(provider: .claude, cacheRoot: root)
        _ = try CostUsageClaudeCacheIO.save(provider: .claude, cache: cache, cacheRoot: root)
        CostUsageClaudeCacheIO.evictArtifactMemoForTesting(at: url)
        let mappings = LockedValue((live: 0, total: 0))
        let reader: @Sendable (URL, Data.ReadingOptions) -> Data? = { url, options in
            #expect(options == .mappedIfSafe)
            let fd = open(url.path, O_RDONLY)
            guard fd >= 0, let stamp = CostUsageClaudeFileStamp.read(at: url) else { return nil }
            defer { close(fd) }
            let size = Int(stamp.size)
            guard let pointer = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0),
                  pointer != MAP_FAILED else { return nil }
            mappings.withLock { $0.live += 1; $0.total += 1 }
            return Data(bytesNoCopy: pointer, count: size, deallocator: .custom { pointer, size in
                munmap(pointer, size)
                mappings.withLock { $0.live -= 1 }
            })
        }
        let decoded = CostUsageClaudeCacheIO.$readForTesting.withValue(reader) {
            CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: root)
        }
        #expect(mappings.withLock { $0.live == 0 && $0.total == 1 })
        #expect(try self.encoder.encode(decoded) == self.encoder.encode(cache))
        #expect(try self.encoder.encode(CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: root))
            == self.encoder.encode(cache))
    }

    @Test
    func `cancellation after streaming preserves old ranges and removes the temporary file`() throws {
        try CostUsageClaudeFragments.$shared.withValue(CostUsageClaudeFragments()) {
            let root = self.directory.url
            var cache = CostUsageClaudeCache()
            cache.usage.files["file"] = self.file(1)
            let initial = try CostUsageClaudeCacheIO.save(provider: .claude, cache: cache, cacheRoot: root)
            cache.usage.files["file"]?.mtimeUnixMs += 1
            let calls = LockedValue(0)
            #expect(throws: CancellationError.self) {
                try CostUsageClaudeCacheIO.save(provider: .claude, cache: cache, cacheRoot: root, checkCancellation: {
                    if calls.withLock({ $0 += 1; return $0 }) == 2 { throw CancellationError() }
                })
            }
            let url = CostUsageClaudeCacheIO.cacheFileURL(provider: .claude, cacheRoot: root)
            #expect(CostUsageClaudeFileStamp.read(at: url) == initial)
            #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
                == [url.lastPathComponent])
            let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
            try CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
                _ = try CostUsageClaudeCacheIO.save(provider: .claude, cache: cache, cacheRoot: root)
            }
            #expect(recorder.snapshot().fragmentEncodes == 1)
            #expect(recorder.persistenceSnapshot().writes == 1)
        }
    }

    @Test
    func `identical streamed bytes keep the inode and reusable offsets`() throws {
        try CostUsageClaudeFragments.$shared.withValue(CostUsageClaudeFragments()) {
            let root = self.directory.url
            var cache = CostUsageClaudeCache()
            cache.usage.files["file"] = self.file(1)
            let initial = try CostUsageClaudeCacheIO.save(provider: .claude, cache: cache, cacheRoot: root)
            let url = CostUsageClaudeCacheIO.cacheFileURL(provider: .claude, cacheRoot: root)
            cache = try JSONDecoder().decode(CostUsageClaudeCache.self, from: Data(contentsOf: url))
            let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
            try CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
                #expect(try CostUsageClaudeCacheIO.save(provider: .claude, cache: cache, cacheRoot: root) == initial)
                #expect(recorder.persistenceSnapshot().writes == 0)
                cache.usage.lastScanUnixMs += 1
                _ = try CostUsageClaudeCacheIO.save(provider: .claude, cache: cache, cacheRoot: root)
            }
            #expect(recorder.snapshot().cacheEncodes == 2)
            #expect(recorder.snapshot().fragmentEncodes == 0)
            #expect(recorder.persistenceSnapshot().writes == 1)
            #expect(try Data(contentsOf: url) == self.encoder.encode(cache))
        }
    }

    @Test
    func `range lengths preserve the previous conservative eviction budget`() throws {
        var file = self.file(1)
        file.claudeRows = try Array(repeating: #require(file.claudeRows?.first), count: 100)
        let memo = try CostUsageClaudeFragments(byteLimit: self.encoder.encode(file).count)
        var cache = CostUsageClaudeCache()
        cache.usage.files["file"] = file
        let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
        try CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
            for _ in 0..<2 {
                _ = try self.encode(memo, cache, at: URL(fileURLWithPath: "/synthetic/budget"))
            }
        }
        #expect(recorder.snapshot().fragmentEncodes == 2)
    }
}
