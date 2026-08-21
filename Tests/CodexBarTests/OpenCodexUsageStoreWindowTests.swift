import Foundation
import Testing
@testable import CodexBarCore

struct OpenCodexUsageStoreWindowTests {
    @Test
    func `window start covers inclusive report history`() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_787_079_600)
        let expected = try calendar.startOfDay(for: #require(calendar.date(byAdding: .day, value: -364, to: now)))

        #expect(OpenCodexUsageStore.windowStart(
            now: now,
            historyDays: 365,
            calendar: calendar) == expected)
        #expect(OpenCodexUsageStore.windowStart(now: now, historyDays: 0, calendar: calendar) == nil)
    }

    @Test
    func `empty cache hit does not force JSONL reparse`() throws {
        let fixture = StoreCacheFixture()
        try fixture.prepare()
        defer { fixture.cleanup() }
        let store = OpenCodexUsageStore(cacheRoot: fixture.cacheRoot)

        _ = try store.loadEntries(logURL: fixture.logURL)
        try FileManager.default.setAttributes([
            .posixPermissions: 0o000,
        ], ofItemAtPath: fixture.logURL.path)
        let cached = try store.loadEntries(logURL: fixture.logURL)

        #expect(cached.isEmpty)
    }
}

private struct StoreCacheFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "codexbar-open-codex-window-\(UUID().uuidString)")

    var logURL: URL {
        self.root.appendingPathComponent("usage.jsonl")
    }

    var cacheRoot: URL {
        self.root.appendingPathComponent("cache")
    }

    func prepare() throws {
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        try Data().write(to: self.logURL)
    }

    func cleanup() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: self.logURL.path)
        try? FileManager.default.removeItem(at: self.root)
    }
}
