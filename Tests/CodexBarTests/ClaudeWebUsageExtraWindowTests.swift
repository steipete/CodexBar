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
    func `ignores merged claude web API omelette usage window`() throws {
        let json = """
        {
          "five_hour": { "utilization": 9, "resets_at": "2025-12-23T16:00:00.000Z" },
          "seven_day_omelette": { "utilization": 26, "resets_at": "2025-12-30T23:00:00.000Z" },
          "seven_day_cowork": { "utilization": 11, "resets_at": "2025-12-31T23:00:00.000Z" }
        }
        """
        let data = Data(json.utf8)
        let parsed = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(data)
        #expect(parsed.extraRateWindows.count == 1)
        #expect(parsed.extraRateWindows.contains { $0.id == "claude-design" } == false)
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
        #expect(parsed.extraRateWindows.contains { $0.id == "claude-design" } == false)
    }

    @Test
    func `surfaces Fable scoped weekly limit from claude web API limits array`() throws {
        // Real shape observed 2026-07-03 from claude.ai/api/organizations/{org}/usage during
        // Anthropic's Fable 5 promotional access window (up to 50% of the weekly limit).
        let json = """
        {
          "five_hour": { "utilization": 16, "resets_at": "2026-07-03T00:30:00.440902+00:00" },
          "seven_day": { "utilization": 10, "resets_at": "2026-07-08T09:00:00.440924+00:00" },
          "limits": [
            {
              "kind": "session", "group": "session", "percent": 16,
              "resets_at": "2026-07-03T00:30:00.440902+00:00", "scope": null, "is_active": true
            },
            {
              "kind": "weekly_all", "group": "weekly", "percent": 10,
              "resets_at": "2026-07-08T09:00:00.440924+00:00", "scope": null, "is_active": false
            },
            {
              "kind": "weekly_scoped", "group": "weekly", "percent": 5,
              "resets_at": "2026-07-08T09:00:00.441154+00:00",
              "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null },
              "is_active": false
            }
          ]
        }
        """
        let data = Data(json.utf8)
        let parsed = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(data)
        let fable = parsed.extraRateWindows.first(where: { $0.id == "claude-weekly-scoped-fable" })
        #expect(fable?.title == "Fable only")
        #expect(fable?.window.usedPercent == 5)
        #expect(fable?.window.resetsAt != nil)
    }
}
