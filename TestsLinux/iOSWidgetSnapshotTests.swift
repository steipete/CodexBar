import Foundation
import Testing
@testable import CodexBariOSShared

@Suite
struct iOSWidgetSnapshotTests {
    @Test
    func decodeSnapshotAndComputeSummaries() throws {
        let json = """
        {
          "entries": [
            {
              "provider": "codex",
              "updatedAt": "2026-02-08T12:00:00Z",
              "primary": {"usedPercent": 25, "windowMinutes": 300, "resetsAt": null, "resetDescription": "Resets in 3h"},
              "secondary": {"usedPercent": 50, "windowMinutes": 10080, "resetsAt": null, "resetDescription": "Resets in 4d"},
              "tertiary": null,
              "creditsRemaining": 123.4,
              "codeReviewRemainingPercent": 80,
              "tokenUsage": {"sessionCostUSD": 1.2, "sessionTokens": 1200, "last30DaysCostUSD": 45.6, "last30DaysTokens": 32000},
              "dailyUsage": []
            }
          ],
          "enabledProviders": ["codex"],
          "generatedAt": "2026-02-08T12:00:00Z"
        }
        """

        let data = try #require(json.data(using: .utf8))
        let snapshot = try iOSWidgetSnapshot.decode(from: data)
        let summaries = snapshot.providerSummaries

        #expect(summaries.count == 1)
        #expect(summaries[0].providerID == "codex")
        #expect(summaries[0].sessionRemainingPercent == 75)
        #expect(summaries[0].weeklyRemainingPercent == 50)
        #expect(summaries[0].creditsRemaining == 123.4)
    }

    @Test
    func selectedProviderFallsBackToFirstAvailable() {
        let snapshot = iOSWidgetSnapshot(
            entries: [
                .init(
                    providerID: "claude",
                    updatedAt: Date(),
                    primary: nil,
                    secondary: nil,
                    tertiary: nil,
                    creditsRemaining: nil,
                    codeReviewRemainingPercent: nil,
                    tokenUsage: nil,
                    dailyUsage: []),
            ],
            enabledProviderIDs: ["claude"],
            generatedAt: Date())

        let selected = snapshot.selectedProviderID(preferred: "codex")
        #expect(selected == "claude")
    }
}
