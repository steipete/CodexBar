import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeWebUsageExtraWindowTests {
    @Test
    func `parses claude web API sonnet usage response`() throws {
        let json = """
        {
          "five_hour": { "utilization": 9, "resets_at": "2025-12-23T16:00:00.000Z" },
          "seven_day_sonnet": { "utilization": 6, "resets_at": "2025-12-30T23:00:00.000Z" }
        }
        """
        let data = Data(json.utf8)
        let parsed = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(data)
        #expect(parsed.opusPercentUsed == 6)
    }

    @Test
    func `parses claude web API omelette and cowork usage windows`() throws {
        let json = """
        {
          "five_hour": { "utilization": 9, "resets_at": "2025-12-23T16:00:00.000Z" },
          "seven_day_omelette": { "utilization": 26, "resets_at": "2025-12-30T23:00:00.000Z" },
          "seven_day_cowork": { "utilization": 11, "resets_at": "2025-12-31T23:00:00.000Z" }
        }
        """
        let data = Data(json.utf8)
        let parsed = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(data)
        #expect(parsed.extraRateWindows.count == 2)
        #expect(parsed.extraRateWindows.first(where: { $0.id == "claude-design" })?.window.usedPercent == 26)
        #expect(parsed.extraRateWindows.first(where: { $0.id == "claude-routines" })?.window.usedPercent == 11)
    }

    @Test
    func `parses claude web API cowork null as zero routines window`() throws {
        let json = """
        {
          "five_hour": { "utilization": 9, "resets_at": "2025-12-23T16:00:00.000Z" },
          "seven_day_omelette": { "utilization": 26, "resets_at": "2025-12-30T23:00:00.000Z" },
          "seven_day_cowork": null
        }
        """
        let data = Data(json.utf8)
        let parsed = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(data)
        #expect(parsed.extraRateWindows.first(where: { $0.id == "claude-routines" })?.window.usedPercent == 0)
    }
}
