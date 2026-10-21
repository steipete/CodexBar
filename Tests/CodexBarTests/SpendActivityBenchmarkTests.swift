import Foundation
import Testing
@testable import CodexBar

struct SpendActivityBenchmarkTests {
    @Test
    func `measure synthetic annual activity helpers`() throws {
        guard ProcessInfo.processInfo.environment["CODEXBAR_ACTIVITY_BENCHMARK"] == "1" else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let locale = Locale(identifier: "zh_Hans_CN")
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 12)))
        let points = try (0..<365).map { offset in
            try SpendDashboardModel.TokenActivityPoint(
                day: #require(calendar.date(byAdding: .day, value: -offset, to: now)),
                totalTokens: offset)
        }
        let series = SpendActivitySeries.make(from: points, now: now, calendar: calendar)
        let dates = points.map(\.day)
        var checksum = 0
        func measure(_ name: String, operation: () -> Int) {
            var samples: [Double] = []
            for sample in 0..<24 {
                let start = ContinuousClock.now
                checksum &+= operation()
                let elapsed = start.duration(to: .now).components
                if sample >= 3 {
                    samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
                }
            }
            print("ACTIVITY_BENCHMARK \(name) median_ms=\(samples.sorted()[samples.count / 2]) samples=21")
        }
        measure("365_medium_dates") {
            dates.reduce(0) {
                $0 + SpendActivityDateFormatting.mediumDateString($1, calendar: calendar, locale: locale).utf8.count
            }
        }
        measure("dates_coverage_weeks") {
            series.daily.indices.compactMap(series.date).count + series.coveredDayCount
                + series.visibleDayCount + series.weeklyActivity().values.reduce(0, +)
        }
        measure("make_and_coverage") {
            SpendActivitySeries.make(from: points, now: now, calendar: calendar).coveredDayCount
        }
        #expect(checksum > 0)
    }
}
