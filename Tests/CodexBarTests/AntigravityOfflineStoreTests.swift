import Foundation
import Testing
@testable import CodexBarCore

struct AntigravityOfflineStoreTests {
    @Test
    func `resolves gemini home from env override`() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let envOverride = "/tmp/custom-gemini"
        let resolved = AntigravityOfflineStore.geminiHomeDirectory(
            home: home,
            env: ["GEMINI_CLI_HOME": envOverride])
        #expect(resolved.path == envOverride)
        let fallback = AntigravityOfflineStore.geminiHomeDirectory(home: home, env: [:])
        #expect(fallback.path == "/Users/test/.gemini")
    }

    @Test
    func `counts db files in conversations directory`() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let conv = AntigravityOfflineStore.conversationsDirectory(home: tmp, env: [:])
        try FileManager.default.createDirectory(at: conv, withIntermediateDirectories: true)
        #expect(AntigravityOfflineStore.countConversations(home: tmp) == 0)
        #expect(!AntigravityOfflineStore.hasOfflineData(home: tmp))
        FileManager.default.createFile(atPath: conv.appendingPathComponent("a.db").path, contents: Data())
        FileManager.default.createFile(atPath: conv.appendingPathComponent("b.DB").path, contents: Data())
        FileManager.default.createFile(atPath: conv.appendingPathComponent("c.txt").path, contents: Data())
        #expect(AntigravityOfflineStore.countConversations(home: tmp) == 2)
        #expect(AntigravityOfflineStore.hasOfflineData(home: tmp))
    }

    @Test
    func `falls back to tokscale cache when no db`() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cache = AntigravityOfflineStore.tokscaleCacheDirectory(home: tmp)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: cache.appendingPathComponent("x.jsonl").path, contents: Data())
        FileManager.default.createFile(atPath: cache.appendingPathComponent("y.jsonl").path, contents: Data())
        #expect(AntigravityOfflineStore.countConversations(home: tmp) == 2)
    }

    @Test
    func `prefers db count over cache`() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let conv = AntigravityOfflineStore.conversationsDirectory(home: tmp, env: [:])
        let cache = AntigravityOfflineStore.tokscaleCacheDirectory(home: tmp)
        try FileManager.default.createDirectory(at: conv, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: conv.appendingPathComponent("a.db").path, contents: Data())
        FileManager.default.createFile(atPath: cache.appendingPathComponent("x.jsonl").path, contents: Data())
        FileManager.default.createFile(atPath: cache.appendingPathComponent("y.jsonl").path, contents: Data())
        #expect(AntigravityOfflineStore.countConversations(home: tmp) == 1)
    }
}
