import CodexBarCore
import Foundation
import Testing

struct OpenAIDashboardModelsTests {
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static func utcDate(year: Int, month: Int, day: Int) -> Date {
        self.utcCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

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

    @Test
    func `usage breakdown converts dashboard exec credits to cost snapshot`() throws {
        let updatedAt = Self.utcDate(year: 2026, month: 6, day: 19)
        let snapshot = OpenAIDashboardSnapshot(
            signedInEmail: "codex@example.com",
            codeReviewRemainingPercent: nil,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [
                OpenAIDashboardDailyBreakdown(
                    day: "2026-06-18",
                    services: [
                        OpenAIDashboardServiceUsage(service: "Exec", creditsUsed: 25),
                    ],
                    totalCreditsUsed: 25),
                OpenAIDashboardDailyBreakdown(
                    day: "2026-06-19",
                    services: [
                        OpenAIDashboardServiceUsage(service: "Exec", creditsUsed: 457.34),
                        OpenAIDashboardServiceUsage(service: "Desktop App", creditsUsed: 33.65),
                        OpenAIDashboardServiceUsage(service: "Skillusage:imagegen", creditsUsed: 9),
                    ],
                    totalCreditsUsed: 500),
            ],
            creditsPurchaseURL: nil,
            updatedAt: updatedAt)

        let cost = try #require(snapshot.toCostUsageTokenSnapshot(
            historyDays: 30,
            now: updatedAt,
            calendar: Self.utcCalendar))

        #expect(cost.valueBasis == .codexDashboardCredits)
        #expect(cost.sessionTokens == nil)
        #expect(cost.last30DaysTokens == nil)
        #expect(abs((cost.sessionCostUSD ?? 0) - 19.6396) < 0.0001)
        #expect(abs((cost.last30DaysCostUSD ?? 0) - 20.6396) < 0.0001)
        #expect(cost.daily.map(\.date) == ["2026-06-18", "2026-06-19"])
        #expect(cost.daily.last?.modelsUsed == ["Exec", "Desktop App"])
        let modelBreakdowns = try #require(cost.daily.last?.modelBreakdowns)
        #expect(modelBreakdowns.map(\.modelName) == ["Exec", "Desktop App"])
        #expect(abs((modelBreakdowns[0].costUSD ?? 0) - 18.2936) < 0.0001)
        #expect(abs((modelBreakdowns[1].costUSD ?? 0) - 1.346) < 0.0001)
        #expect(cost.updatedAt == updatedAt)
    }

    @Test
    func `usage breakdown cost snapshot merges local token context without replacing dashboard USD`() throws {
        let updatedAt = Self.utcDate(year: 2026, month: 6, day: 19)
        let snapshot = OpenAIDashboardSnapshot(
            signedInEmail: "codex@example.com",
            codeReviewRemainingPercent: nil,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [
                OpenAIDashboardDailyBreakdown(
                    day: "2026-06-19",
                    services: [
                        OpenAIDashboardServiceUsage(service: "Exec", creditsUsed: 457.34),
                        OpenAIDashboardServiceUsage(service: "Desktop App", creditsUsed: 33.65),
                    ],
                    totalCreditsUsed: 490.99),
            ],
            creditsPurchaseURL: nil,
            updatedAt: updatedAt)
        let local = CostUsageTokenSnapshot(
            sessionTokens: 30_000_000,
            sessionCostUSD: 28.23,
            last30DaysTokens: 4_700_000_000,
            last30DaysCostUSD: 3528.07,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-06-19",
                    inputTokens: 20_000_000,
                    outputTokens: 10_000_000,
                    totalTokens: 30_000_000,
                    costUSD: 28.23,
                    modelsUsed: ["gpt-5.5"],
                    modelBreakdowns: [
                        .init(modelName: "gpt-5.5", costUSD: 28.23, totalTokens: 30_000_000),
                    ]),
            ],
            updatedAt: updatedAt.addingTimeInterval(-60))

        let cost = try #require(snapshot.toCostUsageTokenSnapshot(
            historyDays: 30,
            merging: local,
            now: updatedAt,
            calendar: Self.utcCalendar))

        #expect(cost.valueBasis == .codexDashboardCredits)
        #expect(cost.sessionTokens == 30_000_000)
        #expect(cost.last30DaysTokens == 4_700_000_000)
        #expect(abs((cost.sessionCostUSD ?? 0) - 19.6396) < 0.0001)
        #expect(abs((cost.last30DaysCostUSD ?? 0) - 19.6396) < 0.0001)
        let day = try #require(cost.daily.first)
        #expect(day.totalTokens == 30_000_000)
        #expect(abs((day.costUSD ?? 0) - 19.6396) < 0.0001)
        #expect(day.modelsUsed == ["Exec", "Desktop App"])
        #expect(day.modelBreakdowns?.map(\.modelName) == ["Exec", "Desktop App"])
    }

    @Test
    func `stale dashboard day does not become todays USD estimate`() throws {
        let snapshot = OpenAIDashboardSnapshot(
            signedInEmail: "codex@example.com",
            codeReviewRemainingPercent: nil,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [
                OpenAIDashboardDailyBreakdown(
                    day: "2026-06-19",
                    services: [OpenAIDashboardServiceUsage(service: "Exec", creditsUsed: 25)],
                    totalCreditsUsed: 25),
            ],
            creditsPurchaseURL: nil,
            updatedAt: Self.utcDate(year: 2026, month: 6, day: 19))

        let cost = try #require(snapshot.toCostUsageTokenSnapshot(
            historyDays: 30,
            now: Self.utcDate(year: 2026, month: 6, day: 20),
            calendar: Self.utcCalendar))

        #expect(cost.sessionCostUSD == nil)
        #expect(cost.last30DaysCostUSD == 1)
        #expect(cost.daily.map(\.date) == ["2026-06-19"])
    }
}
