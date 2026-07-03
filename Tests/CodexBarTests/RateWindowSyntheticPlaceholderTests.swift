import Foundation
import Testing
@testable import CodexBarCore

/// Coverage for `RateWindow.isSyntheticPlaceholder` — the boundary marker that lets lane classifiers
/// distinguish Claude web's `five_hour: null` placeholder from a real zero-usage session. Verifies the
/// marker is set at the web boundary, survives Codable (with backward compatibility), and survives the
/// reset backfill that previously defeated a shape-only heuristic.
struct RateWindowSyntheticPlaceholderTests {
    @Test
    func `synthetic placeholder flag round-trips through Codable`() throws {
        let window = RateWindow(
            usedPercent: 0,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: nil,
            isSyntheticPlaceholder: true)

        let data = try JSONEncoder().encode(window)
        let decoded = try JSONDecoder().decode(RateWindow.self, from: data)

        #expect(decoded.isSyntheticPlaceholder == true)
        #expect(decoded.usedPercent == 0)
        #expect(decoded.windowMinutes == 300)
    }

    @Test
    func `older payload without the flag decodes as not a placeholder`() throws {
        // Cached payloads written before the flag existed have no `isSyntheticPlaceholder` key.
        let json = #"{"usedPercent": 50, "windowMinutes": 300}"#
        let decoded = try JSONDecoder().decode(RateWindow.self, from: Data(json.utf8))

        #expect(decoded.isSyntheticPlaceholder == false)
        #expect(decoded.usedPercent == 50)
        #expect(decoded.windowMinutes == 300)
    }

    @Test
    func `a real window omits the placeholder flag when encoded`() throws {
        let window = RateWindow(usedPercent: 50, windowMinutes: 300, resetsAt: nil, resetDescription: nil)

        let data = try JSONEncoder().encode(window)
        let json = String(bytes: data, encoding: .utf8) ?? ""

        // The flag is only persisted when true, so real windows keep their prior on-disk shape.
        #expect(json.contains("isSyntheticPlaceholder") == false)
    }

    @Test
    func `backfilling a reset preserves the synthetic placeholder flag`() {
        // Regression: backfilling a still-future cached reset onto the placeholder (which has no reset)
        // must NOT let it masquerade as a real session — the marker has to survive the backfill.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cached = RateWindow(
            usedPercent: 12,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(3600),
            resetDescription: "Resets in 1h")
        let placeholder = RateWindow(
            usedPercent: 0,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: nil,
            isSyntheticPlaceholder: true)

        let result = placeholder.backfillingResetTime(from: cached, now: now)

        #expect(result.resetsAt == now.addingTimeInterval(3600))
        #expect(result.isSyntheticPlaceholder == true)
    }

    @Test
    func `web mapping flags the null five-hour session as a synthetic placeholder`() throws {
        let json = """
        {
          "five_hour": null,
          "seven_day": { "utilization": 42, "resets_at": "2025-12-29T23:00:00.000Z" }
        }
        """
        let webData = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(Data(json.utf8))
        let primary = ClaudeUsageFetcher.webPrimaryWindow(from: webData)

        #expect(primary.isSyntheticPlaceholder == true)
        #expect(primary.usedPercent == 0)
        #expect(primary.windowMinutes == 300)
        #expect(primary.resetsAt == nil)
    }

    @Test
    func `web mapping keeps a real five-hour session unflagged`() throws {
        let json = """
        {
          "five_hour": { "utilization": 11, "resets_at": "2025-12-29T20:00:00.000Z" },
          "seven_day": { "utilization": 42, "resets_at": "2025-12-29T23:00:00.000Z" }
        }
        """
        let webData = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(Data(json.utf8))
        let primary = ClaudeUsageFetcher.webPrimaryWindow(from: webData)

        #expect(primary.isSyntheticPlaceholder == false)
        #expect(primary.usedPercent == 11)
    }

    @Test
    func `web mapping keeps a real zero-usage session that omits a reset`() throws {
        // A reported `five_hour` object at 0% with no `resets_at` is a real idle session, not the
        // `five_hour: null` placeholder. The flag keys off object presence (not percent/reset), so this
        // must stay unflagged — otherwise the combined metric would hide a genuine empty session.
        let json = """
        {
          "five_hour": { "utilization": 0 },
          "seven_day": { "utilization": 42, "resets_at": "2025-12-29T23:00:00.000Z" }
        }
        """
        let webData = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(Data(json.utf8))
        let primary = ClaudeUsageFetcher.webPrimaryWindow(from: webData)

        #expect(primary.isSyntheticPlaceholder == false)
        #expect(primary.usedPercent == 0)
        #expect(primary.resetsAt == nil)
    }
}
