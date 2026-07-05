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
    func `recent credit totals use calendar days and exclude future rows`() {
        let summary = OpenAIDashboardDailyBreakdown.recentUsageSummary(
            from: [
                .init(day: "2026-05-31", services: [], totalCreditsUsed: 100),
                .init(day: "2026-06-01", services: [], totalCreditsUsed: 1),
                .init(day: "2026-06-29", services: [], totalCreditsUsed: 2),
                .init(day: "2026-06-30", services: [], totalCreditsUsed: 3),
                .init(day: "2026-07-01", services: [], totalCreditsUsed: 200),
            ],
            historyDays: 30,
            now: Self.utcDate(year: 2026, month: 6, day: 30),
            calendar: Self.utcCalendar)

        #expect(summary.historyDays == 30)
        #expect(summary.todayCredits == 3)
        #expect(summary.totalCredits == 6)
        #expect(summary.daily.map(\.day) == ["2026-06-01", "2026-06-29", "2026-06-30"])
    }

    @Test
    func `recent credit totals preserve gaps and sanitize invalid values`() throws {
        let summary = OpenAIDashboardDailyBreakdown.recentUsageSummary(
            from: [
                .init(
                    day: "2026-06-20",
                    services: [
                        .init(service: "CLI", creditsUsed: 4),
                        .init(service: "bad", creditsUsed: .nan),
                        .init(service: "negative", creditsUsed: -2),
                    ],
                    totalCreditsUsed: 999),
                .init(day: "2026-06-31", services: [], totalCreditsUsed: 9),
                .init(day: "2026-06-30", services: [], totalCreditsUsed: .infinity),
            ],
            now: Self.utcDate(year: 2026, month: 6, day: 30),
            calendar: Self.utcCalendar)

        #expect(summary.todayCredits == 0)
        #expect(summary.totalCredits == 4)
        let day = try #require(summary.daily.first)
        #expect(day.day == "2026-06-20")
        #expect(day.totalCreditsUsed == 4)
        #expect(day.services.map(\.service) == ["CLI"])
    }

    @Test
    func `recent credit totals report zero when history has no row for today`() {
        let summary = OpenAIDashboardDailyBreakdown.recentUsageSummary(
            from: [
                .init(day: "2026-06-29", services: [], totalCreditsUsed: 4),
            ],
            now: Self.utcDate(year: 2026, month: 6, day: 30),
            calendar: Self.utcCalendar)

        #expect(summary.todayCredits == 0)
        #expect(summary.totalCredits == 4)
        #expect(summary.daily.map(\.day) == ["2026-06-29"])
    }

    @Test
    func `recent credit totals fail closed on overflow`() {
        let summary = OpenAIDashboardDailyBreakdown.recentUsageSummary(
            from: [
                .init(
                    day: "2026-06-30",
                    services: [
                        .init(service: "CLI", creditsUsed: Double.greatestFiniteMagnitude),
                        .init(service: "Desktop App", creditsUsed: Double.greatestFiniteMagnitude),
                    ],
                    totalCreditsUsed: 1),
            ],
            now: Self.utcDate(year: 2026, month: 6, day: 30),
            calendar: Self.utcCalendar)

        #expect(summary.daily.isEmpty)
        #expect(summary.todayCredits == nil)
        #expect(summary.totalCredits == nil)
    }

    @Test
    func `recent credit totals respect the selected timezone`() throws {
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-07-01T06:30:00Z"))

        let summary = OpenAIDashboardDailyBreakdown.recentUsageSummary(
            from: [
                .init(day: "2026-06-30", services: [], totalCreditsUsed: 7),
                .init(day: "2026-07-01", services: [], totalCreditsUsed: 11),
            ],
            now: now,
            calendar: pacific)

        #expect(summary.todayCredits == 7)
        #expect(summary.totalCredits == 7)
        #expect(summary.daily.map(\.day) == ["2026-06-30"])
    }

    @Test
    func `recent credit totals keep Gregorian dashboard keys with a non Gregorian system calendar`() throws {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = try #require(TimeZone(secondsFromGMT: 0))

        let summary = OpenAIDashboardDailyBreakdown.recentUsageSummary(
            from: [.init(day: "2026-06-30", services: [], totalCreditsUsed: 7)],
            now: Self.utcDate(year: 2026, month: 6, day: 30),
            calendar: buddhist)

        #expect(summary.todayCredits == 7)
        #expect(summary.totalCredits == 7)
    }
}
