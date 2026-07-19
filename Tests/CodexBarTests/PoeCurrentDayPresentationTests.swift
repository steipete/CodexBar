import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct PoeCurrentDayPresentationTests {
    @Test
    func `Poe notes and dashboard do not label stale usage as Today`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/London"))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-23T12:00:00Z"))
        let yesterday = try #require(ISO8601DateFormatter().date(from: "2026-06-22T12:00:00Z"))
        let usage = PoeUsageHistorySnapshot(
            entries: [
                .init(
                    id: "stale",
                    createdAt: yesterday,
                    model: "GPT-4o",
                    usageType: "chat",
                    points: 100,
                    costUSD: 0.10),
            ],
            daily: [
                .init(day: "2026-06-22", points: 100, requests: 1, costUSD: 0.10),
            ],
            updatedAt: now)

        let notes = UsageMenuCardView.Model.poeUsageNotes(usage, now: now, calendar: calendar)
        let dashboard = UsageMenuCardView.Model.poeInlineDashboard(usage, now: now, calendar: calendar)

        #expect(notes.first == "Today: 0 points · 0 requests")
        #expect(dashboard.kpis.first?.title == "Today")
        #expect(dashboard.kpis.first?.value == "0 points")
        #expect(!dashboard.detailLines.contains(where: { $0.hasPrefix("Today USD:") }))
    }
}
