import Foundation
import Testing
@testable import CodexBarCore

struct PiSessionCostCacheReplacementTests {
    @Test
    func `repeated Pi cache saves preserve scan state and provider totals`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-cache-replacement-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let url = PiSessionCostCacheIO.cacheFileURL(cacheRoot: root)

        for revision in 1...10 {
            var cache = PiSessionCostCache()
            cache.lastScanUnixMs = Int64(revision)
            cache.pricingKey = "pricing-\(revision)"
            cache.daysByProvider = ["codex": ["2026-09-06": ["sample-model": PiPackedUsage(
                inputTokens: revision, totalTokens: revision, costNanos: Int64(revision))]]]
            PiSessionCostCacheIO.save(cache: cache, cacheRoot: root, calendar: calendar)

            let persisted = try JSONDecoder().decode(PiSessionCostCache.self, from: Data(contentsOf: url))
            #expect(persisted.lastScanUnixMs == cache.lastScanUnixMs)
            #expect(persisted.pricingKey == cache.pricingKey)
            #expect(persisted.daysByProvider == cache.daysByProvider)
            #expect(persisted.timeZoneIdentifier == calendar.timeZone.identifier)
            #expect(PiSessionCostCacheIO.load(cacheRoot: root).lastScanUnixMs == cache.lastScanUnixMs)
        }

        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(files == [url.lastPathComponent])
    }
}
