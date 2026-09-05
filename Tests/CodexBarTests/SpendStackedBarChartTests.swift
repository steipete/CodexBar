import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct SpendStackedBarChartTests {
    private static func dailyPoint(
        sourceID: String,
        day: Date,
        stackStart: Double,
        stackEnd: Double) -> SpendDashboardModel.DailyPoint
    {
        SpendDashboardModel.DailyPoint(
            sourceID: sourceID,
            provider: .codex,
            providerName: sourceID,
            day: day,
            cost: stackEnd - stackStart,
            stackStart: stackStart,
            stackEnd: stackEnd)
    }

    @Test
    func `topmost id is picked among more than two stacked providers`() {
        let day = Date(timeIntervalSince1970: 0)
        let bottom = Self.dailyPoint(sourceID: "claude", day: day, stackStart: 0, stackEnd: 10)
        let middle = Self.dailyPoint(sourceID: "codex", day: day, stackStart: 10, stackEnd: 18)
        let top = Self.dailyPoint(sourceID: "cursor", day: day, stackStart: 18, stackEnd: 30)

        let topIDs = spendTopOfStackIDs(
            for: [bottom, middle, top],
            key: \.day,
            id: \.id,
            stackEnd: \.stackEnd)

        #expect(topIDs == [top.id])
    }

    @Test
    func `single segment day is its own top of stack`() {
        let day = Date(timeIntervalSince1970: 0)
        let onlySegment = Self.dailyPoint(sourceID: "claude", day: day, stackStart: 0, stackEnd: 5)

        let topIDs = spendTopOfStackIDs(
            for: [onlySegment],
            key: \.day,
            id: \.id,
            stackEnd: \.stackEnd)

        #expect(topIDs == [onlySegment.id])
    }

    @Test
    func `each day gets its own top of stack independently`() {
        let day1 = Date(timeIntervalSince1970: 0)
        let day2 = Date(timeIntervalSince1970: 86400)
        let day1Bottom = Self.dailyPoint(sourceID: "claude", day: day1, stackStart: 0, stackEnd: 10)
        let day1Top = Self.dailyPoint(sourceID: "codex", day: day1, stackStart: 10, stackEnd: 20)
        let day2Only = Self.dailyPoint(sourceID: "claude", day: day2, stackStart: 0, stackEnd: 3)

        let topIDs = spendTopOfStackIDs(
            for: [day1Bottom, day1Top, day2Only],
            key: \.day,
            id: \.id,
            stackEnd: \.stackEnd)

        #expect(topIDs == [day1Top.id, day2Only.id])
    }

    @Test
    func `trailing zero cost segments do not replace the visible top`() {
        let day = Date(timeIntervalSince1970: 0)
        let a = Self.dailyPoint(sourceID: "claude", day: day, stackStart: 0, stackEnd: 10)
        let b = Self.dailyPoint(sourceID: "codex", day: day, stackStart: 10, stackEnd: 10)

        let topIDs = spendTopOfStackIDs(
            for: [a, b],
            key: \.day,
            id: \.id,
            stackEnd: \.stackEnd)

        #expect(topIDs == [a.id])
    }

    @Test
    func `empty points yield no top of stack ids`() {
        let topIDs = spendTopOfStackIDs(
            for: [SpendDashboardModel.DailyPoint](),
            key: \.day,
            id: \.id,
            stackEnd: \.stackEnd)

        #expect(topIDs.isEmpty)
    }
}
