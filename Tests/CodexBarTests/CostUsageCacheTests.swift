import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageCacheTests {
    @Test
    func `cache file URL uses provider artifact versions`() {
        let root = URL(fileURLWithPath: "/tmp/codexbar-cost-cache", isDirectory: true)

        let codexURL = CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: root)
        let claudeURL = CostUsageCacheIO.cacheFileURL(provider: .claude, cacheRoot: root)
        let vertexURL = CostUsageCacheIO.cacheFileURL(provider: .vertexai, cacheRoot: root)

        #expect(codexURL.lastPathComponent == "codex-v8.json")
        #expect(claudeURL.lastPathComponent == "claude-v4.json")
        #expect(vertexURL.lastPathComponent == "vertexai-v4.json")
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
    func `current codex cache accepts parser compatible 0_33 producer`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var cache = CostUsageCache()
        cache.lastScanUnixMs = 123
        cache.days = ["2026-05-18": ["gpt-5.5": [1, 2, 3]]]
        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: root,
            producerKey: "codex:cu:p3c27f997569eb3c5")

        let loaded = CostUsageCacheIO.load(provider: .codex, cacheRoot: root)

        #expect(loaded.lastScanUnixMs == 123)
        #expect(loaded.days["2026-05-18"]?["gpt-5.5"] == [1, 2, 3])
    }

    @Test
    func `current codex cache accepts project metadata migration producer`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var cache = CostUsageCache()
        cache.lastScanUnixMs = 123
        cache.days = ["2026-05-18": ["gpt-5.5": [1, 2, 3]]]
        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: root,
            producerKey: "codex:cu:pc54070a94f6419ea")

        let loaded = CostUsageCacheIO.load(provider: .codex, cacheRoot: root)

        #expect(loaded.lastScanUnixMs == 123)
        #expect(loaded.days["2026-05-18"]?["gpt-5.5"] == [1, 2, 3])
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

    private func makeTemporaryCacheRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-cost-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
