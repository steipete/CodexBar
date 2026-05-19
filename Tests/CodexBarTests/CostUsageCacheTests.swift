import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageCacheTests {
    @Test
    func `cache file URL uses codex specific artifact version`() {
        let root = URL(fileURLWithPath: "/tmp/codexbar-cost-cache", isDirectory: true)

        let codexURL = CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: root)
        let claudeURL = CostUsageCacheIO.cacheFileURL(provider: .claude, cacheRoot: root)

        #expect(codexURL.lastPathComponent == "codex-v8.json")
        #expect(claudeURL.lastPathComponent == "claude-v2.json")
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
            producerKey: "codex:cost-usage:1.0.0")

        let loaded = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: root,
            producerKey: "codex:cost-usage:1.0.0")
        #expect(loaded.producerKey == "codex:cost-usage:1.0.0")
        #expect(loaded.lastScanUnixMs == 123)
        #expect(loaded.days["2026-05-18"]?["gpt-5.5"] == [1, 2, 3])

        let stale = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: root,
            producerKey: "codex:cost-usage:1.0.1")
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
            producerKey: "codex:cost-usage:1.0.0")

        #expect(loaded.lastScanUnixMs == 0)
        #expect(loaded.days.isEmpty)
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
    func `current producer key only applies to codex`() {
        let codexKey = CostUsageCacheIO.currentProducerKey(
            provider: .codex,
            executablePath: nil)
        let claudeKey = CostUsageCacheIO.currentProducerKey(
            provider: .claude,
            executablePath: nil)

        #expect(codexKey == "codex:cost-usage:development")
        #expect(claudeKey == nil)
    }

    @Test
    func `producer key uses adjacent version file for release cli`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let binURL = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        let helperURL = binURL.appendingPathComponent("CodexBarCLI")
        try Data().write(to: helperURL)
        try "v1.2.3\n".write(
            to: binURL.appendingPathComponent("VERSION"),
            atomically: false,
            encoding: .utf8)

        let key = CostUsageCacheIO.currentProducerKey(
            provider: .codex,
            executablePath: helperURL.path)

        #expect(key == "codex:cost-usage:1.2.3")
    }

    @Test
    func `producer key uses containing app marketing version`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let appURL = root.appendingPathComponent("CodexBar.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let helpersURL = contentsURL.appendingPathComponent("Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpersURL, withIntermediateDirectories: true)

        let infoURL = contentsURL.appendingPathComponent("Info.plist")
        let plist: [String: Any] = [
            "CFBundleShortVersionString": "9.8.7",
            "CFBundleVersion": "42",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: infoURL)

        let helperURL = helpersURL.appendingPathComponent("CodexBarCLI")
        try Data().write(to: helperURL)

        let key = CostUsageCacheIO.currentProducerKey(
            provider: .codex,
            executablePath: helperURL.path)

        #expect(key == "codex:cost-usage:9.8.7")
    }

    @Test
    func `producer key matches app and standalone cli for same release`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let appURL = root.appendingPathComponent("CodexBar.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let helpersURL = contentsURL.appendingPathComponent("Helpers", isDirectory: true)
        let standaloneURL = root.appendingPathComponent("standalone", isDirectory: true)
        try FileManager.default.createDirectory(at: helpersURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: standaloneURL, withIntermediateDirectories: true)

        let infoURL = contentsURL.appendingPathComponent("Info.plist")
        let plist: [String: Any] = [
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "99",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: infoURL)

        let bundledHelperURL = helpersURL.appendingPathComponent("CodexBarCLI")
        try Data().write(to: bundledHelperURL)

        let standaloneHelperURL = standaloneURL.appendingPathComponent("CodexBarCLI")
        try Data().write(to: standaloneHelperURL)
        try "1.2.3\n".write(
            to: standaloneURL.appendingPathComponent("VERSION"),
            atomically: false,
            encoding: .utf8)

        let appKey = CostUsageCacheIO.currentProducerKey(
            provider: .codex,
            executablePath: bundledHelperURL.path)
        let standaloneKey = CostUsageCacheIO.currentProducerKey(
            provider: .codex,
            executablePath: standaloneHelperURL.path)

        #expect(appKey == "codex:cost-usage:1.2.3")
        #expect(standaloneKey == appKey)
    }

    @Test
    func `producer key fingerprints development executable`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let helperURL = root.appendingPathComponent("CodexBarCLI")
        try Data("dev".utf8).write(to: helperURL)

        let key = CostUsageCacheIO.currentProducerKey(
            provider: .codex,
            executablePath: helperURL.path)

        #expect(key?.hasPrefix("codex:cost-usage:development+3-") == true)
    }

    private func makeTemporaryCacheRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-cost-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
