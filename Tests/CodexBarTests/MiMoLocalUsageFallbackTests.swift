import Foundation
import Testing
@testable import CodexBarCore

struct MiMoLocalUsageFallbackTests {
    @Test
    func `returns nil when cache file is missing`() {
        let snap = MiMoLocalUsageFallback.snapshot(
            cachePath: "/nonexistent/path/that/should/never/exist.json",
            now: Date())
        #expect(snap == nil)
    }

    @Test
    func `returns nil when cache file is malformed JSON`() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimo-fallback-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("malformed.json")
        try "{not json".write(to: file, atomically: true, encoding: .utf8)

        let snap = MiMoLocalUsageFallback.snapshot(cachePath: file.path, now: Date())
        #expect(snap == nil)
    }

    @Test
    func `returns nil when cache schema is incomplete`() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimo-fallback-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("incomplete.json")
        try Data("{}".utf8).write(to: file)

        let snap = MiMoLocalUsageFallback.snapshot(cachePath: file.path, now: Date())
        #expect(snap == nil)
    }

    @Test
    func `parses all token buckets without fabricating a quota window`() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimo-fallback-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("usage.json")
        let updatedAt = "2026-06-03T05:04:03.123456+00:00"
        let payload: [String: Any] = [
            "updated_at": updatedAt,
            "sessions_scanned": 1296,
            "windows": [
                "today": ["input": 1500, "output": 500, "cache_read": 0, "cache_create": 250, "messages": 3],
                "week": [
                    "input": 30000,
                    "output": 10000,
                    "cache_read": 60000,
                    "cache_create": 10000,
                    "messages": 25,
                ],
                "all_time": [
                    "input": 3_600_000,
                    "output": 1_100_000,
                    "cache_read": 16_100_000,
                    "cache_create": 2_000_000,
                    "messages": 1315,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: file)

        let snap = try #require(MiMoLocalUsageFallback.snapshot(cachePath: file.path, now: Date()))

        // planCode packs today/week/total/sessions in one row.
        let plan = try #require(snap.planCode)
        #expect(plan.contains("today"))
        #expect(plan.contains("week"))
        #expect(plan.contains("total"))
        #expect(plan.contains("1296 sessions"))
        #expect(plan.contains("110.0k week"))
        #expect(plan.contains("22.8M total"))
        #expect(snap.tokenUsed == 0)
        #expect(snap.tokenLimit == 0)
        #expect(snap.tokenPercent == 0)
        let usage = snap.toUsageSnapshot(includeBalance: false)
        #expect(usage.primary == nil)
        #expect(usage.mimoUsage == nil)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(snap.updatedAt == formatter.date(from: updatedAt))
    }

    @Test
    func `idle week keeps local accounting in the plan summary`() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimo-fallback-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("idle.json")
        let payload: [String: Any] = [
            "sessions_scanned": 100,
            "windows": [
                "today": ["input": 0, "output": 0, "cache_read": 0],
                "week": ["input": 0, "output": 0, "cache_read": 0],
                "all_time": ["input": 500_000, "output": 250_000, "cache_read": 1_250_000],
            ],
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: file)

        let snap = try #require(MiMoLocalUsageFallback.snapshot(cachePath: file.path, now: Date()))
        #expect(snap.tokenUsed == 0)
        #expect(snap.tokenLimit == 0)
        #expect(snap.tokenPercent == 0)
        #expect(snap.toUsageSnapshot(includeBalance: false).mimoUsage == nil)
        let plan = try #require(snap.planCode)
        #expect(plan.hasPrefix("Local"))
        #expect(!plan.contains("today"))
        #expect(!plan.contains("week"))
        #expect(plan.contains("total"))
        #expect(plan.contains("100 sessions"))
    }
}
