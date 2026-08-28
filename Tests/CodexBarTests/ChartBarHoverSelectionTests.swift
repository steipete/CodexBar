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
    func `hovering an inset plot bar center returns that bar and its frame`() throws {
        let plotFrame = CGRect(x: 52, y: 11, width: 240, height: 120)
        let bars = ChartBarHoverSelection.bars(
            plotFrame: plotFrame,
            unitIntervals: [0...40, 40...80, 80...120, 120...160, 160...200, 200...240],
            widthRatio: 0.7)
        let expectedBar = try #require(bars.first { $0.index == 3 })

        let selection = try #require(ChartBarHoverSelection.selection(
            at: CGPoint(x: expectedBar.frame.midX, y: plotFrame.midY),
            plotFrame: plotFrame,
            bars: bars))

        #expect(selection.index == 3)
        #expect(selection.highlightFrame == expectedBar.frame)
    }

    @Test
    func `calendar day bars use interval midpoint instead of interval start`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let date = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 8)))
        let plotFrame = CGRect(x: 37, y: 9, width: 200, height: 80)
        let secondsPerPoint = 60.0 * 60.0
        let origin = date.addingTimeInterval(-12 * 60 * 60)

        let bars = try #require(ChartBarHoverSelection.calendarDayBars(
            dates: [date],
            plotFrame: plotFrame,
            calendar: calendar,
            position: { CGFloat($0.timeIntervalSince(origin) / secondsPerPoint) }))
        let bar = try #require(bars.first)

        #expect(abs(bar.frame.midX - (plotFrame.minX + 23.5)) < 0.0001)
        #expect(abs(bar.frame.width - (23 * ChartBarHoverSelection.barWidthRatio)) < 0.0001)
    }
}
