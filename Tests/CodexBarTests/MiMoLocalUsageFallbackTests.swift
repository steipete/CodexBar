import Foundation
import Testing
@testable import CodexBarCore

@Suite
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
    func `parses cache and surfaces lifetime + planCode + progress`() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimo-fallback-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("usage.json")
        let payload: [String: Any] = [
            "sessions_scanned": 1296,
            "windows": [
                "today": ["input": 1500, "output": 500, "cache_read": 0, "cache_create": 0, "messages": 3],
                "week": ["input": 30000, "output": 10000, "cache_read": 60000, "cache_create": 0, "messages": 25],
                "all_time": [
                    "input": 3_600_000,
                    "output": 1_100_000,
                    "cache_read": 16_100_000,
                    "cache_create": 0,
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

        // Progress bar: tokenUsed = week, tokenLimit = max(allTotal, week+1) → bar ~0.2% used.
        let weekSum = 30000 + 10000 + 60000 // 100k
        #expect(snap.tokenUsed == weekSum)
        let allSum = 3_600_000 + 1_100_000 + 16_100_000 // 20.8M
        #expect(snap.tokenLimit == max(allSum, weekSum + 1))
        #expect(snap.tokenPercent > 0)
        #expect(snap.tokenPercent < 0.01) // ~0.5% of lifetime
    }

    @Test
    func `idle week surfaces empty progress with lifetime baseline`() throws {
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
        #expect(snap.tokenLimit == 2_000_000) // allTotal as baseline
        #expect(snap.tokenPercent == 0)
        // planCode skips today/week (both zero) but keeps total + sessions.
        let plan = try #require(snap.planCode)
        #expect(!plan.contains("today"))
        #expect(!plan.contains("week"))
        #expect(plan.contains("total"))
        #expect(plan.contains("100 sessions"))
    }
}
