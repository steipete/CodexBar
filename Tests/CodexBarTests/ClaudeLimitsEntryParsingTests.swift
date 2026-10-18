import Foundation
import Testing
@testable import CodexBarCore

/// OAuth and Web parse the usage `limits` array through the same per-entry parser.
@Suite(.serialized, ClaudeOAuthDefaultsFixtures())
struct ClaudeLimitsEntryParsingTests {
    private static let fableLimit = """
    {
      "kind": "weekly_scoped", "group": "weekly", "percent": 11,
      "resets_at": "2026-10-15T09:00:00+00:00",
      "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null },
      "is_active": false
    }
    """

    private static func payload(_ entries: [String]) -> Data {
        Data("""
        {
          "five_hour": { "utilization": 12.0, "resets_at": "2026-10-11T05:00:00+00:00" },
          "seven_day": { "utilization": 14.0, "resets_at": "2026-10-15T09:00:00+00:00" },
          "limits": [\(entries.joined(separator: ","))]
        }
        """.utf8)
    }

    @Test(arguments: [
        #"{"kind":"session","group":"session","percent":"12","resets_at":null,"scope":null}"#,
        #"{"kind":"session","group":"session","percent":12,"resets_at":1791800000,"scope":null}"#,
        #"{"kind":"session","group":"session","percent":12,"resets_at":null,"scope":"account"}"#,
        #"{"kind":"weekly_all","group":"weekly","percent":14,"scope":{"model":{"id":42}},"is_active":"no"}"#,
    ])
    func `O auth and web keep Fable when a sibling limit entry has an unexpected shape`(sibling: String) throws {
        let data = Self.payload([sibling, Self.fableLimit])
        let oauth = try ClaudeUsageFetcher._mapOAuthUsageForTesting(data)
        let web = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(data)

        #expect(oauth.primary?.usedPercent == 12)
        #expect(oauth.extraRateWindows.map(\.id) == ["claude-weekly-scoped-fable"])
        #expect(web.extraRateWindows.map(\.id) == ["claude-weekly-scoped-fable"])
    }

    @Test
    func `O auth and web show Fable without optional fields of an unexpected type`() throws {
        let fable = """
        {
          "kind": "weekly_scoped", "group": "weekly", "percent": 11, "resets_at": 1791800000,
          "scope": { "model": { "id": 42, "display_name": "Fable" }, "surface": null },
          "is_active": "false"
        }
        """
        let data = Self.payload([fable])
        let oauth = try ClaudeUsageFetcher._mapOAuthUsageForTesting(data).extraRateWindows
        let web = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(data).extraRateWindows

        for windows in [oauth, web] {
            #expect(windows.map(\.id) == ["claude-weekly-scoped-fable"])
            #expect(windows.first?.window.usedPercent == 11)
            #expect(windows.first?.window.resetsAt == nil)
        }
    }
}
