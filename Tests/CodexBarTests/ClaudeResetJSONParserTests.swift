import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeResetJSONParserTests {
    @Test
    func `usage JSON parser applies quota horizons from one clock`() throws {
        let reset = "Jul 9 at 6am (UTC)"
        let json = """
        {
          "ok": true,
          "session_5h": { "pct_used": 1, "resets": "\(reset)" },
          "week_all_models": { "pct_used": 2, "resets": "\(reset)" },
          "week_sonnet": { "pct_used": 3, "resets": "\(reset)" }
        }
        """
        let now = try Self.isoDate("2026-07-09T12:00:00Z")
        let snapshot = try #require(ClaudeUsageFetcher.parse(json: Data(json.utf8), now: now))
        let futureReset = try Self.isoDate("2027-07-09T06:00:00Z")
        let recentReset = try Self.isoDate("2026-07-09T06:00:00Z")

        #expect(snapshot.primary.resetsAt == futureReset)
        #expect(snapshot.secondary?.resetsAt == recentReset)
        #expect(snapshot.opus?.resetsAt == recentReset)
        #expect(snapshot.updatedAt == now)
    }

    @Test
    func `usage JSON parser supports explicit years and preserves malformed reset text`() throws {
        let explicitReset = "Jan 2, 2026, 10:59pm (Europe/Helsinki)"
        let malformedReset = "after the next billing sync"
        let json = """
        {
          "ok": true,
          "session_5h": { "pct_used": 1, "resets": "\(explicitReset)" },
          "week_all_models": { "pct_used": 2, "resets": "\(malformedReset)" }
        }
        """
        let now = try Self.isoDate("2025-01-01T00:00:00Z")
        let snapshot = try #require(ClaudeUsageFetcher.parse(
            json: Data(json.utf8),
            now: now))
        let expectedReset = try Self.isoDate("2026-01-02T20:59:00Z")

        #expect(snapshot.primary.resetsAt == expectedReset)
        #expect(snapshot.primary.resetDescription == explicitReset)
        #expect(snapshot.secondary?.resetsAt == nil)
        #expect(snapshot.secondary?.resetDescription == malformedReset)
    }

    private static func isoDate(_ text: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        return try #require(formatter.date(from: text))
    }
}
