import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeScopedWeeklyLimitWebTests {
    @Test
    func `parses active scoped weekly limit as extra rate window`() throws {
        let json = """
        {
          "five_hour": { "utilization": 9, "resets_at": "2026-07-02T16:00:00.000Z" },
          "seven_day": { "utilization": 34, "resets_at": "2026-07-08T06:00:00.000Z" },
          "limits": [
            { "kind": "session", "group": "session", "percent": 9, "severity": "normal",
              "resets_at": "2026-07-02T16:00:00+00:00", "scope": null, "is_active": true },
            { "kind": "weekly_all", "group": "weekly", "percent": 34, "severity": "normal",
              "resets_at": "2026-07-08T06:00:00+00:00", "scope": null, "is_active": true },
            { "kind": "weekly_scoped", "group": "weekly", "percent": 70, "severity": "normal",
              "resets_at": "2026-07-08T06:00:00+00:00",
              "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null },
              "is_active": true }
          ]
        }
        """
        let parsed = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(Data(json.utf8))

        let fable = try #require(parsed.extraRateWindows.first { $0.id == "claude-scoped-fable" })
        #expect(fable.title == "Fable weekly")
        #expect(fable.window.usedPercent == 70)
        #expect(fable.window.windowMinutes == 7 * 24 * 60)
        #expect(fable.window.resetsAt != nil)
        // Legacy fields stay authoritative; session/weekly limits[] kinds are not duplicated.
        #expect(parsed.extraRateWindows.count == 1)
        #expect(parsed.sessionPercentUsed == 9)
        #expect(parsed.weeklyPercentUsed == 34)
    }

    @Test
    func `includes inactive scoped weekly limit when percent is present`() throws {
        let json = """
        {
          "five_hour": { "utilization": 9, "resets_at": "2026-07-02T16:00:00.000Z" },
          "limits": [
            { "kind": "weekly_scoped", "group": "weekly", "percent": 0, "severity": "normal",
              "resets_at": "2026-07-08T06:00:00+00:00",
              "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null },
              "is_active": false }
          ]
        }
        """
        let parsed = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(Data(json.utf8))

        let fable = try #require(parsed.extraRateWindows.first { $0.id == "claude-scoped-fable" })
        #expect(fable.window.usedPercent == 0)
    }

    @Test
    func `skips scoped weekly limit without percent`() throws {
        let json = """
        {
          "five_hour": { "utilization": 9, "resets_at": "2026-07-02T16:00:00.000Z" },
          "limits": [
            { "kind": "weekly_scoped", "group": "weekly", "percent": null, "severity": "normal",
              "resets_at": "2026-07-08T06:00:00+00:00",
              "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null },
              "is_active": true }
          ]
        }
        """
        let parsed = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(Data(json.utf8))

        #expect(parsed.extraRateWindows.isEmpty)
    }

    @Test
    func `legacy payload without limits array is unchanged`() throws {
        let json = """
        {
          "five_hour": { "utilization": 9, "resets_at": "2026-07-02T16:00:00.000Z" },
          "seven_day": { "utilization": 34, "resets_at": "2026-07-08T06:00:00.000Z" },
          "seven_day_cowork": { "utilization": 11, "resets_at": "2026-07-08T06:00:00.000Z" }
        }
        """
        let parsed = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(Data(json.utf8))

        #expect(parsed.sessionPercentUsed == 9)
        #expect(parsed.weeklyPercentUsed == 34)
        #expect(parsed.extraRateWindows.count == 1)
        #expect(parsed.extraRateWindows.first?.id == "claude-routines")
    }
}

struct ClaudeScopedWeeklyLimitOAuthTests {
    @Test
    func `maps active scoped weekly limit as extra rate window`() throws {
        let json = """
        {
          "five_hour": { "utilization": 12.5, "resets_at": "2026-07-02T16:00:00.000Z" },
          "seven_day": { "utilization": 34, "resets_at": "2026-07-08T06:00:00.000Z" },
          "limits": [
            { "kind": "session", "group": "session", "percent": 12, "severity": "normal",
              "resets_at": "2026-07-02T16:00:00+00:00", "scope": null, "is_active": true },
            { "kind": "weekly_all", "group": "weekly", "percent": 34, "severity": "normal",
              "resets_at": "2026-07-08T06:00:00+00:00", "scope": null, "is_active": true },
            { "kind": "weekly_scoped", "group": "weekly", "percent": 70, "severity": "normal",
              "resets_at": "2026-07-08T06:00:00+00:00",
              "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null },
              "is_active": true }
          ]
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(json.utf8))

        let fable = try #require(snap.extraRateWindows.first { $0.id == "claude-scoped-fable" })
        #expect(fable.title == "Fable weekly")
        #expect(fable.window.usedPercent == 70)
        #expect(fable.window.windowMinutes == 7 * 24 * 60)
        #expect(fable.window.resetsAt != nil)
        // Legacy fields stay authoritative; session/weekly limits[] kinds are not duplicated.
        #expect(snap.extraRateWindows.count == 1)
        #expect(snap.primary.usedPercent == 12.5)
        #expect(snap.secondary?.usedPercent == 34)
    }

    @Test
    func `maps inactive scoped weekly limit when percent is present`() throws {
        let json = """
        {
          "five_hour": { "utilization": 12.5, "resets_at": "2026-07-02T16:00:00.000Z" },
          "limits": [
            { "kind": "weekly_scoped", "group": "weekly", "percent": 5, "severity": "normal",
              "resets_at": "2026-07-08T06:00:00+00:00",
              "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null },
              "is_active": false }
          ]
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(json.utf8))

        let fable = try #require(snap.extraRateWindows.first { $0.id == "claude-scoped-fable" })
        #expect(fable.window.usedPercent == 5)
    }

    @Test
    func `legacy payload without limits array is unchanged`() throws {
        let json = """
        {
          "five_hour": { "utilization": 12.5, "resets_at": "2026-07-02T16:00:00.000Z" },
          "seven_day": { "utilization": 34, "resets_at": "2026-07-08T06:00:00.000Z" },
          "seven_day_routines": { "utilization": 18, "resets_at": "2026-07-08T06:00:00.000Z" }
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(json.utf8))

        #expect(snap.primary.usedPercent == 12.5)
        #expect(snap.secondary?.usedPercent == 34)
        #expect(snap.extraRateWindows.count == 1)
        #expect(snap.extraRateWindows.first?.id == "claude-routines")
    }
}
