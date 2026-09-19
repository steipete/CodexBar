import Foundation
import Testing
@testable import CodexBarCore

extension CostUsageFetcherCacheSnapshotTests {
    @Test(arguments: [
        "valid",
        "empty",
        "missing",
        "zero-time",
        "version",
        "pricing",
        "timezone",
        "range",
        "scoped-missing",
    ])
    func `early native window publication retains strict pi coverage and measurement time`(
        _ kind: String) async throws
    {
        let fixture = try CodexCurrentWindowFixture(kind: .historical)
        defer { fixture.base.remove() }
        #expect(await fixture.strictSnapshot() != nil)
        let measuredAt = fixture.base.now.addingTimeInterval(-1800)
        if kind != "missing", kind != "scoped-missing" {
            if kind != "empty" {
                try Self.writeCurrentWindowPiSession(fixture)
            }
            let options = PiSessionCostScanner.Options(
                piSessionsRoot: fixture.base.env.piSessionsRoot,
                ompSessionsRoot: fixture.base.env.root.appendingPathComponent("empty-omp"),
                cacheRoot: fixture.base.env.cacheRoot,
                calendar: fixture.base.calendar,
                refreshMinIntervalSeconds: 0)
            _ = PiSessionCostScanner.loadDailyReport(
                provider: .codex,
                since: fixture.base.now,
                until: fixture.base.now,
                now: fixture.base.now,
                options: options)
            var cache = PiSessionCostCacheIO.load(cacheRoot: fixture.base.env.cacheRoot)
            #expect(cache.lastScanUnixMs > 0)
            cache.lastScanUnixMs = Int64(measuredAt.timeIntervalSince1970 * 1000)
            var calendar = fixture.base.calendar
            switch kind {
            case "zero-time": cache.lastScanUnixMs = 0
            case "version": cache.version = -1
            case "pricing": cache.pricingKey = "synthetic-incompatible-pricing"
            case "timezone": calendar.timeZone = try #require(TimeZone(secondsFromGMT: 3600))
            case "range": cache.scanSinceKey = "2026-08-02"
            default: break
            }
            PiSessionCostCacheIO.save(cache: cache, cacheRoot: fixture.base.env.cacheRoot, calendar: calendar)
        }
        let scoped = kind == "scoped-missing"
        let cached = await CostUsageFetcher.loadCachedCodexTokenSnapshotResult(
            now: fixture.base.now.addingTimeInterval(120),
            codexHomePath: scoped ? fixture.base.env.codexHomeRoot.path : nil,
            historyDays: 1,
            allowScopedCodexHome: true,
            requireCompleteHistory: true,
            scannerOptions: fixture.base.options)
        if kind == "valid" || kind == "empty" || scoped {
            let cached = try #require(cached)
            #expect(cached.snapshot.last30DaysTokens == (kind == "valid" ? 217 : 52))
            #expect(cached.snapshot.updatedAt == (scoped ? fixture.base.now : measuredAt))
            #expect(cached.lastRefreshAt == (scoped ? fixture.base.now : nil))
            #expect(cached.staleSnapshotUpdatedAt == nil)
        } else {
            #expect(cached == nil)
        }
    }

    private static func writeCurrentWindowPiSession(_ fixture: CodexCurrentWindowFixture) throws {
        let env = fixture.base.env
        _ = try env.writePiSessionFile(
            relativePath: "current-window.jsonl",
            contents: env.jsonl([[
                "type": "message",
                "timestamp": env.isoString(for: fixture.base.now),
                "message": [
                    "role": "assistant",
                    "provider": "openai-codex",
                    "model": "openai/gpt-5.4",
                    "timestamp": Int(fixture.base.now.timeIntervalSince1970 * 1000),
                    "usage": ["input": 165, "output": 0, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 165],
                ],
            ]]))
    }
}
