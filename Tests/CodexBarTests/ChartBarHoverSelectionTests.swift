import Foundation
import Testing
@testable import CodexBar

struct ChartBarHoverSelectionTests {
    @Test
    func `single selectable bar accepts the full plot`() {
        #expect(ChartBarHoverSelection.accepts(
            distanceFromBarCenter: 120,
            barHalfWidth: 5,
            selectableCount: 1))
    }

    @Test
    func `multiple selectable bars accept only the bar body`() {
        #expect(ChartBarHoverSelection.accepts(
            distanceFromBarCenter: 5,
            barHalfWidth: 5,
            selectableCount: 2))
        #expect(!ChartBarHoverSelection.accepts(
            distanceFromBarCenter: 5.1,
            barHalfWidth: 5,
            selectableCount: 2))
    }

    @Test
    func `calendar day spacing follows daylight saving transitions`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let springDate = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 7,
            hour: 12)))
        let fallDate = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 10,
            day: 31,
            hour: 12)))

        let springNextDay = ChartBarHoverSelection.nextCalendarDay(after: springDate, calendar: calendar)
        let fallNextDay = ChartBarHoverSelection.nextCalendarDay(after: fallDate, calendar: calendar)

        #expect(calendar.component(.day, from: springNextDay) == 8)
        #expect(springNextDay.timeIntervalSince(springDate) == 23 * 60 * 60)
        #expect(calendar.component(.day, from: fallNextDay) == 1)
        #expect(fallNextDay.timeIntervalSince(fallDate) == 25 * 60 * 60)
    }
}
