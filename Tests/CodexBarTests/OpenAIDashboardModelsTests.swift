import CodexBarCore
import Foundation
import Testing

struct OpenAIDashboardModelsTests {
    @Test
    func `removes skill usage services from usage breakdown`() {
        let breakdown = [
            OpenAIDashboardDailyBreakdown(
                day: "2026-04-30",
                services: [
                    OpenAIDashboardServiceUsage(service: "Desktop App", creditsUsed: 10),
                    OpenAIDashboardServiceUsage(service: "Skillusage:imagegen", creditsUsed: 7),
                    OpenAIDashboardServiceUsage(service: " skillusage:github:github ", creditsUsed: 2),
                ],
                totalCreditsUsed: 19),
            OpenAIDashboardDailyBreakdown(
                day: "2026-04-29",
                services: [
                    OpenAIDashboardServiceUsage(service: "Skillusage:deep Research", creditsUsed: 3),
                ],
                totalCreditsUsed: 3),
        ]

        let filtered = OpenAIDashboardDailyBreakdown.removingSkillUsageServices(from: breakdown)

        #expect(filtered == [
            OpenAIDashboardDailyBreakdown(
                day: "2026-04-30",
                services: [
                    OpenAIDashboardServiceUsage(service: "Desktop App", creditsUsed: 10),
                ],
                totalCreditsUsed: 10),
        ])
    }

    @Test
    func `snapshot initializer sanitizes usage breakdown`() {
        let snapshot = OpenAIDashboardSnapshot(
            signedInEmail: "codex@example.com",
            codeReviewRemainingPercent: nil,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [
                OpenAIDashboardDailyBreakdown(
                    day: "2026-04-30",
                    services: [
                        OpenAIDashboardServiceUsage(service: "CLI", creditsUsed: 4),
                        OpenAIDashboardServiceUsage(service: "Skillusage:pdf Renderer", creditsUsed: 6),
                    ],
                    totalCreditsUsed: 10),
            ],
            creditsPurchaseURL: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(snapshot.usageBreakdown == [
            OpenAIDashboardDailyBreakdown(
                day: "2026-04-30",
                services: [
                    OpenAIDashboardServiceUsage(service: "CLI", creditsUsed: 4),
                ],
                totalCreditsUsed: 4),
        ])
    }

    @Test
    func `snapshot decoder drops empty zero usage buckets`() throws {
        let json = """
        {
          "signedInEmail": "codex@example.com",
          "codeReviewRemainingPercent": null,
          "creditEvents": [],
          "dailyBreakdown": [],
          "usageBreakdown": [
            { "day": "2026-04-30", "services": [], "totalCreditsUsed": 0 },
            { "day": "2026-04-29", "services": [], "totalCreditsUsed": 4 }
          ],
          "creditsPurchaseURL": null,
          "updatedAt": "2026-04-30T19:27:07Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let snapshot = try decoder.decode(OpenAIDashboardSnapshot.self, from: Data(json.utf8))

        #expect(snapshot.usageBreakdown == [
            OpenAIDashboardDailyBreakdown(
                day: "2026-04-29",
                services: [],
                totalCreditsUsed: 4),
        ])
    }
}
