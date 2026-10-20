import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized, CostUsageClaudeCacheFixtures())
struct CostUsageClaudeIncrementalPersistenceTests {
    private typealias Fixture = CostUsageClaudeWriteAmplificationTests.Fixture

    @Test
    func `one changed project keeps other shards and writes bounded bytes`() throws {
        let fixture = try Fixture(rowCount: 1)
        defer { fixture.env.cleanup() }
        var cache = CostUsageClaudeCache()
        for project in 0..<40 {
            for file in 0..<200 {
                cache.usage.files["/synthetic/project-\(project)/file-\(file)"] = CostUsageFileUsage(
                    mtimeUnixMs: 1, size: 1, days: [:], parsedBytes: 1, claudeRows: [])
            }
        }
        _ = try CostUsageClaudeCacheIO.save(provider: .claude, cache: cache, cacheRoot: fixture.env.cacheRoot)
        let url = fixture.cacheURL(context: .regular)
        let before = try self.shards(url)
        cache.usage.files["/synthetic/project-0/file-0"]?.size = 10000
        let counter = Counter()
        let observer: @Sendable (Int) -> Void = { counter.add($0) }
        try CostUsageClaudeArtifactWriter.$observeWrittenBytesForTesting.withValue(observer) {
            _ = try CostUsageClaudeCacheIO.save(provider: .claude, cache: cache, cacheRoot: fixture.env.cacheRoot)
        }
        let after = try self.shards(url)
        #expect(Set(before.values).intersection(after.values).count == 39)
        #expect(counter.bytes < 1_000_000)
        CostUsageClaudeCacheIO.evictArtifactMemoForTesting(at: url)
        let loaded = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: fixture.env.cacheRoot)
        #expect(loaded.usage.files.count == 8000)
        #expect(loaded.usage.files["/synthetic/project-0/file-0"]?.size == 10000)
        #expect(loaded.usage.files["/synthetic/project-39/file-199"]?.parsedBytes == 1)
    }

    @Test
    func `interrupted save leaves the previous complete snapshot and reclaims orphan shards`() throws {
        let fixture = try Fixture(rowCount: 1)
        defer { fixture.env.cleanup() }
        _ = try fixture.load(context: .regular)
        let url = fixture.cacheURL(context: .regular)
        let initial = try Data(contentsOf: url)
        var cache = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: fixture.env.cacheRoot)
        let path = try #require(cache.usage.files.keys.first)
        let oldSize = cache.usage.files[path]?.size
        cache.usage.files[path]?.size = 123_456
        let interrupt: @Sendable () throws -> Void = { throw CancellationError() }
        #expect(throws: CancellationError.self) {
            try CostUsageClaudeFragments.$beforeManifestForTesting.withValue(interrupt) {
                _ = try CostUsageClaudeCacheIO.save(provider: .claude, cache: cache, cacheRoot: fixture.env.cacheRoot)
            }
        }
        #expect(try Data(contentsOf: url) == initial)
        CostUsageClaudeCacheIO.evictArtifactMemoForTesting(at: url)
        CostUsageClaudeFragments.shared.evict(at: url)
        let recovered = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: fixture.env.cacheRoot)
        #expect(recovered.usage.files[path]?.size == oldSize)
        _ = try CostUsageClaudeCacheIO.save(provider: .claude, cache: cache, cacheRoot: fixture.env.cacheRoot)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.appendingPathExtension("fragments").path)
        #expect(try Set(names.filter { $0.hasSuffix(".json") }) == Set(self.shards(url).values))
    }

    @Test
    func `missing and corrupt shards reject the whole snapshot`() throws {
        for missing in [false, true] {
            let fixture = try Fixture(rowCount: 1)
            defer { fixture.env.cleanup() }
            _ = try fixture.load(context: .regular)
            let url = fixture.cacheURL(context: .regular)
            let name = try #require(self.shards(url).values.first)
            let shard = url.appendingPathExtension("fragments").appendingPathComponent(name)
            if missing { try FileManager.default.removeItem(at: shard) } else {
                try Data("{}".utf8).write(to: shard)
            }
            CostUsageClaudeCacheIO.evictArtifactMemoForTesting(at: url)
            CostUsageClaudeFragments.shared.evict(at: url)
            #expect(CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: fixture.env.cacheRoot).usage.files
                .isEmpty)
        }
    }

    @Test
    func `legacy cache and memo migrate with a tail parse and remain downgrade safe`() throws {
        let fixture = try Fixture(rowCount: 1)
        defer { fixture.env.cleanup() }
        let initial = try fixture.load(context: .regular)
        let url = fixture.cacheURL(context: .regular)
        let memoURL = CostUsageClaudeReportMemo.reportMemoFileURL(cacheFileURL: url)
        let cache = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: fixture.env.cacheRoot)
        var memo = try claudeMemoObjectForTesting(at: memoURL)
        try JSONEncoder().encode(cache).write(to: url, options: .atomic)
        let stamp = try #require(CostUsageClaudeFileStamp.read(at: url))
        var key = try #require(memo["reportKey"] as? [String: Any])
        key["cacheArtifactStamp"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stamp))
        memo["reportKey"] = key
        try JSONSerialization.data(withJSONObject: memo).write(to: memoURL, options: .atomic)
        CostUsageClaudeCacheIO.evictArtifactMemoForTesting(at: url)
        CostUsageClaudeFragments.shared.evict(at: memoURL)
        CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: fixture.env.cacheRoot)
        let source = fixture.env.claudeProjectsRoot.appendingPathComponent("session.jsonl")
        let handle = try FileHandle(forWritingTo: source)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(fixture.event(index: 501).utf8))
        try handle.close()
        let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
        let report = try CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
            try fixture.load(context: .regular, cycle: 1)
        }
        #expect(report.summary?.totalInputTokens == (initial.summary?.totalInputTokens ?? 0) + 10)
        #expect(recorder.snapshot().transcriptParses == 1)
        #expect(recorder.snapshot().incrementalTranscriptParses == 1)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CostUsageClaudeCache.self, from: Data(contentsOf: url))
        }
        #expect(try fixture.load(context: .regular, cycle: 2).data == report.data)
    }

    @Test
    func `decoded shard snapshots release mapped input`() throws {
        let fixture = try Fixture(rowCount: 1)
        defer { fixture.env.cleanup() }
        _ = try fixture.load(context: .regular)
        let url = fixture.cacheURL(context: .regular)
        let expected = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: fixture.env.cacheRoot)
        CostUsageClaudeCacheIO.evictArtifactMemoForTesting(at: url)
        let live = Counter()
        let total = Counter()
        let reader: @Sendable (URL, Data.ReadingOptions) -> Data? = { url, options in
            #expect(options == .mappedIfSafe)
            let descriptor = open(url.path, O_RDONLY)
            guard descriptor >= 0, let stamp = CostUsageClaudeFileStamp.read(at: url) else { return nil }
            defer { close(descriptor) }
            let size = Int(stamp.size)
            guard let pointer = mmap(nil, size, PROT_READ, MAP_PRIVATE, descriptor, 0),
                  pointer != MAP_FAILED else { return nil }
            live.add(1)
            total.add(1)
            return Data(bytesNoCopy: pointer, count: size, deallocator: .custom { pointer, size in
                munmap(pointer, size)
                live.add(-1)
            })
        }
        let loaded = CostUsageClaudeCacheIO.$readForTesting.withValue(reader) {
            CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: fixture.env.cacheRoot)
        }
        #expect(loaded.usage == expected.usage)
        #expect(loaded.sourceFileIDs == expected.sourceFileIDs)
        #expect(live.bytes == 0)
        #expect(total.bytes == 2)
    }

    private func shards(_ url: URL) throws -> [String: String] {
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let shards = try #require(object["shards"] as? [String: [String: Any]])
        return try shards.mapValues { try #require($0["digest"] as? String) + ".json" }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var bytes: Int {
            self.lock.withLock { self.value }
        }

        func add(_ value: Int) { self.lock.withLock { self.value += value } }
    }
}
