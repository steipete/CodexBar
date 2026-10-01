import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct ModelsDevIdenticalRefreshTests {
    @Test
    func `identical refresh preserves catalog bytes and stamp while persisting retry time`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let now = Date(timeIntervalSince1970: 100_000)
        let catalog = try Self.catalog()
        #expect(ModelsDevCache.save(
            catalog: catalog,
            fetchedAt: now.addingTimeInterval(-901),
            cacheRoot: env.cacheRoot))
        let url = ModelsDevCache.cacheFileURL(cacheRoot: env.cacheRoot)
        let bytes = try Data(contentsOf: url)
        let stamp = try #require(CostUsageClaudeFileStamp.read(at: url))
        let transport = try Transport(catalog: catalog)
        let client = ModelsDevClient(transport: transport)
        for offset in [0.0, 899, 900, 901] {
            let result = await ModelsDevPricingPipeline.refreshForUnknownModelsIfNeeded(
                providerID: "anthropic",
                modelIDs: ["claude-test-unknown"],
                now: now.addingTimeInterval(offset),
                cacheRoot: env.cacheRoot,
                client: client)
            #expect(result == .unavailable)
            #expect(transport.calls == (offset < 900 ? 1 : 2))
            #expect(CostUsageClaudeFileStamp.read(at: url) == stamp)
            #expect(try Data(contentsOf: url) == bytes)
        }
        // A different path has no coordinator or decoded memo state, like a new process.
        let restartedRoot = env.cacheRoot.appendingPathComponent("restarted")
        let restartedURL = ModelsDevCache.cacheFileURL(cacheRoot: restartedRoot)
        try FileManager.default.createDirectory(
            at: restartedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        // Hard links preserve the catalog identity to exercise persisted refresh metadata.
        try FileManager.default.linkItem(at: url, to: restartedURL)
        try FileManager.default.copyItem(
            at: url.appendingPathExtension("refresh"), to: restartedURL.appendingPathExtension("refresh"))
        let loaded = ModelsDevCache.load(now: now.addingTimeInterval(901), cacheRoot: restartedRoot)
        #expect(loaded.artifact?.fetchedAt == now.addingTimeInterval(900))
        _ = await ModelsDevPricingPipeline.refreshForUnknownModelsIfNeeded(
            providerID: "anthropic",
            modelIDs: ["claude-test-unknown"],
            now: now.addingTimeInterval(901),
            cacheRoot: restartedRoot,
            client: client)
        #expect(transport.calls == 2)
    }

    @Test
    func `identical stale refresh resets ttl and compares after fallback merging`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let now = Date(timeIntervalSince1970: 100_000)
        let catalog = try Self.catalog()
        var fetched = catalog
        fetched.providers["anthropic"]?.models.removeValue(forKey: "claude-test-fallback")
        #expect(ModelsDevCache.save(
            catalog: catalog,
            fetchedAt: now.addingTimeInterval(-ModelsDevCache.ttlSeconds - 1),
            cacheRoot: env.cacheRoot))
        let url = ModelsDevCache.cacheFileURL(cacheRoot: env.cacheRoot)
        let stamp = CostUsageClaudeFileStamp.read(at: url)
        let transport = try Transport(catalog: fetched)
        let client = ModelsDevClient(transport: transport)
        #expect(await ModelsDevPricingPipeline.refreshStaleCache(now: now, cacheRoot: env.cacheRoot, client: client))
        #expect(CostUsageClaudeFileStamp.read(at: url) == stamp)
        #expect(ModelsDevCache.load(now: now, cacheRoot: env.cacheRoot).artifact?.catalog == catalog)
        let boundary = now.addingTimeInterval(ModelsDevCache.ttlSeconds)
        #expect(!ModelsDevCache.load(now: boundary, cacheRoot: env.cacheRoot).isStale)
        #expect(await ModelsDevPricingPipeline.refreshStaleCache(
            now: boundary,
            cacheRoot: env.cacheRoot,
            client: client))
        #expect(transport.calls == 1)
        #expect(ModelsDevCache.load(now: boundary.addingTimeInterval(1), cacheRoot: env.cacheRoot).isStale)
        await ModelsDevPricingPipeline.refreshIfNeeded(
            now: boundary.addingTimeInterval(1), cacheRoot: env.cacheRoot, client: client)
        #expect(transport.calls == 2)
        #expect(CostUsageClaudeFileStamp.read(at: url) == stamp)
    }

    @Test
    func `changed catalog rewrites and ignores refresh metadata from the prior catalog`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let now = Date(timeIntervalSince1970: 100_000)
        let catalog = try Self.catalog()
        #expect(ModelsDevCache.save(catalog: catalog, fetchedAt: now, cacheRoot: env.cacheRoot))
        #expect(ModelsDevCache.save(catalog: catalog, fetchedAt: now.addingTimeInterval(900), cacheRoot: env.cacheRoot))
        let url = ModelsDevCache.cacheFileURL(cacheRoot: env.cacheRoot)
        let stamp = CostUsageClaudeFileStamp.read(at: url)
        let changed = try Self.catalog(rate: 20)
        let transport = try Transport(catalog: changed)
        let refreshedAt = now.addingTimeInterval(1800)
        _ = await ModelsDevPricingPipeline.refreshForUnknownModelsIfNeeded(
            providerID: "anthropic",
            modelIDs: ["claude-test-unknown"],
            now: refreshedAt,
            cacheRoot: env.cacheRoot,
            client: ModelsDevClient(transport: transport))
        #expect(transport.calls == 1)
        #expect(CostUsageClaudeFileStamp.read(at: url) != stamp)
        #expect(ModelsDevCache.load(now: refreshedAt, cacheRoot: env.cacheRoot).artifact?.catalog == changed)
        #expect(ModelsDevCache.load(now: refreshedAt, cacheRoot: env.cacheRoot).artifact?.fetchedAt == refreshedAt)
    }

    @Test
    func `external replacement cannot inherit an identical refresh timestamp`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let now = Date(timeIntervalSince1970: 100_000)
        let catalog = try Self.catalog()
        #expect(ModelsDevCache.save(catalog: catalog, fetchedAt: now, cacheRoot: env.cacheRoot))
        let url = ModelsDevCache.cacheFileURL(cacheRoot: env.cacheRoot)
        let bytes = try Data(contentsOf: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(ModelsDevCache.save(catalog: catalog, fetchedAt: now.addingTimeInterval(900), cacheRoot: env.cacheRoot))
        // Same bytes, size and mtime, but an atomic replacement gets a new inode.
        try bytes.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: #require(attributes[.modificationDate])],
            ofItemAtPath: url.path)
        #expect(ModelsDevCache.load(now: now, cacheRoot: env.cacheRoot).artifact?.fetchedAt == now)
    }

    @Test
    func `replacement between metadata and catalog reads cannot inherit the prior fetch time`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let now = Date(timeIntervalSince1970: 100_000)
        let catalog = try Self.catalog()
        #expect(ModelsDevCache.save(
            catalog: catalog,
            fetchedAt: now.addingTimeInterval(-901),
            cacheRoot: env.cacheRoot))
        #expect(ModelsDevCache.save(catalog: catalog, fetchedAt: now, cacheRoot: env.cacheRoot))
        let replacement = try Self.catalog(rate: 20)
        let old = Date(timeIntervalSince1970: 1)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(ModelsDevCacheArtifact(version: 1, fetchedAt: old, catalog: replacement))
        let url = ModelsDevCache.cacheFileURL(cacheRoot: env.cacheRoot)
        let recorder = ModelsDevCache.MetadataReadRecorder(onRead: {
            try? data.write(to: url, options: .atomic)
        })
        let loaded = ModelsDevCache.withMetadataReadRecorderForTesting(recorder) {
            ModelsDevCache.load(now: now, cacheRoot: env.cacheRoot)
        }
        #expect(recorder.snapshot() == 1)
        #expect(loaded.artifact?.catalog == replacement)
        #expect(loaded.artifact?.fetchedAt == old)
        #expect(loaded.isStale)
    }

    @Test(arguments: [false, true])
    func `missing or corrupt refresh metadata falls back to catalog time`(corrupt: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let now = Date(timeIntervalSince1970: 100_000)
        let catalog = try Self.catalog()
        #expect(ModelsDevCache.save(catalog: catalog, fetchedAt: now, cacheRoot: env.cacheRoot))
        #expect(ModelsDevCache.save(catalog: catalog, fetchedAt: now.addingTimeInterval(900), cacheRoot: env.cacheRoot))
        let url = ModelsDevCache.cacheFileURL(cacheRoot: env.cacheRoot).appendingPathExtension("refresh")
        // Warm the memo before an external sidecar mutation.
        #expect(ModelsDevCache.load(now: now, cacheRoot: env.cacheRoot).artifact?.fetchedAt == now
            .addingTimeInterval(900))
        if corrupt {
            try Data("invalid fixture".utf8).write(to: url, options: .atomic)
        } else {
            try FileManager.default.removeItem(at: url)
        }
        #expect(ModelsDevCache.load(now: now, cacheRoot: env.cacheRoot).artifact?.fetchedAt == now)
    }

    @Test
    func `failed refresh metadata write preserves the last successful fetch`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let now = Date(timeIntervalSince1970: 100_000)
        let catalog = try Self.catalog()
        #expect(ModelsDevCache.save(catalog: catalog, fetchedAt: now, cacheRoot: env.cacheRoot))
        let url = ModelsDevCache.cacheFileURL(cacheRoot: env.cacheRoot)
        let stamp = CostUsageClaudeFileStamp.read(at: url)
        try FileManager.default.createDirectory(
            at: url.appendingPathExtension("refresh"),
            withIntermediateDirectories: true)
        #expect(!ModelsDevCache.save(
            catalog: catalog,
            fetchedAt: now.addingTimeInterval(900),
            cacheRoot: env.cacheRoot))
        #expect(ModelsDevCache.load(now: now, cacheRoot: env.cacheRoot).artifact?.fetchedAt == now)
        #expect(CostUsageClaudeFileStamp.read(at: url) == stamp)
    }

    static func catalog(rate: Double = 10) throws -> ModelsDevCatalog {
        try JSONDecoder().decode(ModelsDevCatalog.self, from: JSONSerialization.data(withJSONObject: [
            "anthropic": ["id": "anthropic", "models": [
                "claude-test-known": ["id": "claude-test-known", "cost": ["input": rate, "output": 1]],
                "claude-test-fallback": ["id": "claude-test-fallback", "cost": ["input": 3, "output": 1]],
            ]],
            "openai": ["id": "openai", "models": [
                "gpt-test-anchor": ["id": "gpt-test-anchor", "cost": ["input": 2, "output": 1]],
            ]],
        ]))
    }

    final class Transport: ModelsDevHTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private let body: Data

        init(catalog: ModelsDevCatalog) throws {
            self.body = try JSONEncoder().encode(catalog)
        }

        var calls: Int {
            self.lock.withLock { self.count }
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            self.lock.withLock { self.count += 1 }
            return (
                self.body,
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
}
