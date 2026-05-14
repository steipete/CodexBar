import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeWebEnterpriseUsageTests {
    @Test
    func `parses usage response when session window is null`() throws {
        let json = """
        {
          "five_hour": null,
          "seven_day": { "utilization": 42, "resets_at": "2025-12-29T23:00:00.000Z" }
        }
        """
        let data = Data(json.utf8)
        let parsed = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(data)
        #expect(parsed.sessionPercentUsed == 0)
        #expect(parsed.weeklyPercentUsed == 42)
    }
}
