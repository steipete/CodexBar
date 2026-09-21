import Foundation
import Testing
@testable import CodexBarCore

struct PiSessionCostCacheLinuxTests {
    @Test
    func `first and replacement saves roundtrip changed cache without temporary files`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = PiSessionCostCacheIO.cacheFileURL(cacheRoot: root)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

        for tokens in [100, 250] {
            var cache = PiSessionCostCache()
            cache.lastScanUnixMs = Int64(tokens)
            cache.scanSinceKey = "2026-08-20"
            cache.scanUntilKey = "2026-08-21"
            cache.pricingKey = "fixture-pricing-\(tokens)"
            cache.daysByProvider = ["codex": ["2026-08-20": [
                "gpt-5.4": PiPackedUsage(inputTokens: tokens, totalTokens: tokens),
            ]]]
            cache.files = [root.appendingPathComponent("session.jsonl").path: PiSessionFileUsage(
                mtimeUnixMs: Int64(tokens),
                size: Int64(tokens),
                parsedBytes: Int64(tokens),
                lastModelContext: nil,
                contributions: cache.daysByProvider)]

            PiSessionCostCacheIO.save(cache: cache, cacheRoot: root, calendar: calendar)

            // Read the final artifact directly so load's empty-cache fallback cannot hide a failed save.
            let data = try Data(contentsOf: url)
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["lastScanUnixMs"] as? Int == tokens)
            let decoded = try JSONDecoder().decode(PiSessionCostCache.self, from: data)
            for saved in [decoded, PiSessionCostCacheIO.load(cacheRoot: root)] {
                #expect(saved.version == cache.version)
                #expect(saved.lastScanUnixMs == cache.lastScanUnixMs)
                #expect(saved.scanSinceKey == cache.scanSinceKey)
                #expect(saved.scanUntilKey == cache.scanUntilKey)
                #expect(saved.pricingKey == cache.pricingKey)
                #expect(saved.timeZoneIdentifier == calendar.timeZone.identifier)
                #expect(saved.daysByProvider == cache.daysByProvider)
                #expect(saved.files.values.first?.parsedBytes == Int64(tokens))
                #expect(saved.files.values.first?.contributions == cache.daysByProvider)
            }
            let contents = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            #expect(contents == [url.lastPathComponent])
        }
    }
}
