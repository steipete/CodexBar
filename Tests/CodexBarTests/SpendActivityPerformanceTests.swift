import Foundation
import Testing
@testable import CodexBar

struct SpendActivityPerformanceTests {
    @Test
    func `date formatting without a reporting calendar retains the system default time zone`() {
        let locale = Locale(identifier: "en_US")
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let date = Date(timeIntervalSince1970: 1_791_410_400)
        #expect(SpendActivityDateFormatting.mediumDateString(date, locale: locale) == formatter.string(from: date))
    }

    @Test
    func `reused date formatters preserve medium dates across locales calendars and time zones`() throws {
        let identifiers: [Calendar.Identifier] = [.gregorian, .buddhist, .japanese, .islamic, .hebrew]
        let locales = ["en_US", "en_GB", "zh_Hans_CN", "zh_Hant_TW", "ja_JP", "ko_KR", "ar_SA", "he_IL"]
        let zones = ["UTC", "Asia/Shanghai", "America/Los_Angeles"]
        let dates = [Date(timeIntervalSince1970: 1_791_374_400), Date(timeIntervalSince1970: 1_730_615_400)]
        for identifier in identifiers {
            for zone in zones {
                var calendar = Calendar(identifier: identifier)
                calendar.timeZone = try #require(TimeZone(identifier: zone))
                for language in locales {
                    let locale = Locale(identifier: language)
                    let formatter = DateFormatter()
                    formatter.locale = locale
                    formatter.calendar = calendar
                    formatter.timeZone = calendar.timeZone
                    formatter.dateStyle = .medium
                    formatter.timeStyle = .none
                    for date in dates {
                        #expect(SpendActivityDateFormatting.mediumDateString(date, calendar: calendar, locale: locale)
                            == formatter.string(from: date))
                    }
                }
            }
        }
    }

    @Test
    func `concurrent date formatting keeps each locale and reporting time zone isolated`() async {
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<64 {
                group.addTask {
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = TimeZone(identifier: index.isMultiple(of: 2) ? "UTC" : "Asia/Shanghai")!
                    let locale = Locale(identifier: index.isMultiple(of: 3) ? "zh_Hans_CN" : "en_US")
                    // Close to midnight UTC, so the two reporting zones have different dates.
                    let date = Date(timeIntervalSince1970: 1_791_410_400)
                    let formatter = DateFormatter()
                    formatter.locale = locale
                    formatter.calendar = calendar
                    formatter.timeZone = calendar.timeZone
                    formatter.dateStyle = .medium
                    formatter.timeStyle = .none
                    let expected = formatter.string(from: date)
                    for _ in 0..<16 {
                        #expect(SpendActivityDateFormatting.mediumDateString(date, calendar: calendar, locale: locale)
                            == expected)
                    }
                }
            }
        }
    }

    @Test(arguments: ["America/Santiago", "America/Los_Angeles", "Asia/Shanghai"])
    func `cached activity dates preserve calendar days through daylight saving transitions`(zone: String) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 12)))
        let points = try (0..<365).map { offset in
            let day = try #require(calendar.date(byAdding: .day, value: -offset, to: now))
            return SpendDashboardModel.TokenActivityPoint(day: day, totalTokens: offset == 9 ? nil : offset)
        }
        let series = SpendActivitySeries.make(from: points, now: now, calendar: calendar)
        #expect(series.visibleDayCount == 365)
        #expect(series.coveredDayCount == 364)
        #expect(series.hasUnknownCoverage)
        for index in series.daily.indices {
            let expected = calendar.date(byAdding: .day, value: index, to: series.start)
                .map { calendar.startOfDay(for: $0) }
            #expect(series.date(at: index) == expected)
            #expect(series.visibleIndices.contains(index) == expected.map { series.rangeStart...series.today ~= $0 })
        }
        #expect(series.visibleIndices.compactMap(series.date).count == 365)
    }
}
