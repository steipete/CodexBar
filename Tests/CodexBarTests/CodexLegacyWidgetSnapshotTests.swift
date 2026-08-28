import Foundation
import Testing
@testable import CodexBarCore
@testable import CodexBarWidget

struct CodexLegacyWidgetSnapshotTests {
    @Test
    func `codex widget caps legacy decoded rows without window metadata`() throws {
        let json = """
        {
          "entries": [
            {
              "provider": "codex",
              "updatedAt": "2027-01-15T08:00:00Z",
              "primary": {
                "usedPercent": 1,
                "windowMinutes": 300,
                "resetsAt": "2027-01-15T09:00:00Z",
                "resetDescription": null
              },
              "secondary": {
                "usedPercent": 100,
                "windowMinutes": 10080,
                "resetsAt": "2027-01-15T10:00:00Z",
                "resetDescription": null
              },
              "tertiary": null,
              "usageRows": [
                { "id": "session", "title": "Session", "percentLeft": 99 },
                { "id": "weekly", "title": "Weekly", "percentLeft": 0 }
              ],
              "creditsRemaining": null,
              "codeReviewRemainingPercent": null,
              "tokenUsage": null,
              "dailyUsage": []
            }
          ],
          "enabledProviders": ["codex"],
          "generatedAt": "2027-01-15T08:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(WidgetSnapshot.self, from: Data(json.utf8))
        let entry = try #require(snapshot.entries.first)
        let now = try #require(ISO8601DateFormatter().date(from: "2027-01-15T08:30:00Z"))

        let rows = WidgetUsageRow.rows(for: entry, now: now)

        #expect(entry.usageRows?.allSatisfy { $0.window == nil } == true)
        #expect(rows.map(\.id) == ["session", "weekly"])
        #expect(rows.map(\.percentLeft) == [0, 0])
    }
}
