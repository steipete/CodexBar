import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageLocalDayTests {
    private static let zones = [
        "America/Los_Angeles", "Europe/Berlin", "Australia/Lord_Howe",
        "Asia/Kathmandu", "Pacific/Apia", "UTC",
    ]

    private static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .buddhist)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private static func reference(_ date: Date, calendar: Calendar) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let components = gregorian.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    @Test
    func `formatter preserves signed printf padding and truncation`() {
        let values = [
            Int.min,
            Int.max,
            -4_294_967_297,
            -2_147_483_648,
            -10000,
            -999,
            -10,
            -1,
            0,
            1,
            9,
            10,
            99,
            999,
            1000,
            9999,
            10000,
            2_147_483_647,
            4_294_967_297,
        ]
        for year in values {
            for month in values {
                for day in values {
                    #expect(CostUsageLocalDay.key(year: year, month: month, day: day)
                        == String(format: "%04d-%02d-%02d", year, month, day))
                }
            }
        }
    }

    @Test(arguments: Self.zones)
    func `random dates and day boundaries match fresh Gregorian calendars`(_ zone: String) throws {
        let calendar = Self.calendar(zone)
        var seed: UInt64 = 42
        for _ in 0..<1000 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            let seconds = -2_208_988_800 + Double(seed % 6_343_056_001)
            let date = Date(timeIntervalSince1970: seconds)
            #expect(CostUsageLocalDay.key(from: date, calendar: calendar) == Self.reference(date, calendar: calendar))
        }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        for (year, month, day) in [
            (2026, 3, 8), (2026, 11, 1), (2026, 3, 29), (2026, 10, 25),
            (2026, 4, 5), (2026, 10, 4), (2011, 12, 29), (2011, 12, 31),
            (-1000, 1, 1), (0, 1, 1), (1, 1, 1), (999, 12, 31), (10000, 1, 1),
        ] {
            let date = try #require(gregorian.date(from: DateComponents(year: year, month: month, day: day)))
            let interval = try #require(gregorian.dateInterval(of: .day, for: date))
            let samples = [
                -0.001,
                0,
                0.001,
                3600,
                7200,
                10800,
                interval.duration - 0.001,
                interval.duration,
                interval.duration + 0.001,
            ]
            for seconds in samples + samples.reversed() {
                let timestamp = interval.start.addingTimeInterval(seconds)
                #expect(CostUsageLocalDay.key(from: timestamp, calendar: calendar)
                    == Self.reference(timestamp, calendar: calendar))
            }
        }
    }

    @Test(arguments: Self.zones)
    func `timestamp offsets and fractions retain legacy day conversion`(_ zone: String) throws {
        let calendar = Self.calendar(zone)
        let fractions = ["", ".0", ".001", ".999999999"]
        for (suffix, offset) in [
            ("Z", 0),
            ("+05:45", 20700),
            ("-08:00", -28800),
            ("+14:00", 50400),
            ("-03:30", -12600),
            ("+0545", 20700),
            ("-08", -28800),
        ] {
            for (year, month, day) in [(2026, 3, 8), (2026, 11, 1), (2011, 12, 30), (999, 1, 1), (0, 1, 1)] {
                for hour in [0, 12, 23] {
                    let date = try #require(DateComponents(
                        calendar: Calendar(identifier: .gregorian),
                        timeZone: TimeZone(secondsFromGMT: offset),
                        year: year,
                        month: month,
                        day: day,
                        hour: hour,
                        minute: 59,
                        second: 59).date)
                    let prefix = String(format: "%04d-%02d-%02dT%02d:59:59", year, month, day, hour)
                    for fraction in fractions {
                        #expect(CostUsageScanner.dayKeyFromTimestamp(prefix + fraction + suffix, calendar: calendar)
                            == Self.reference(date, calendar: calendar))
                    }
                }
            }
        }
    }

    @Test
    func `ten thousand same day keys build components once and invalidate at boundaries`() throws {
        let cache = CostUsageLocalDay.Cache()
        let calendar = Self.calendar("America/Los_Angeles")
        let start = try #require(CostUsageLocalDay.date(fromKey: "2026-03-08", calendar: calendar))
        var builds = 0
        func key(_ date: Date, _ calendar: Calendar) -> String {
            cache.withMemo(calendar: calendar) {
                $0.key(for: date, calendar: calendar) { timestamp, gregorian in
                    builds += 1
                    return CostUsageLocalDay.uncachedKey(from: timestamp, calendar: gregorian)
                }
            }
        }
        for second in 0..<10000 {
            #expect(key(start.addingTimeInterval(Double(second)), calendar) == "2026-03-08")
        }
        #expect(builds == 1)
        let next = start.addingTimeInterval(23 * 3600)
        #expect(key(next.addingTimeInterval(-0.001), calendar) == "2026-03-08")
        #expect(builds == 1)
        #expect(key(next, calendar) == "2026-03-09")
        #expect(builds == 2)
        #expect(key(start, calendar) == "2026-03-08")
        #expect(builds == 3)
        let utc = Self.calendar("UTC")
        #expect(key(start, utc) == Self.reference(start, calendar: utc))
        #expect(builds == 4)
        #expect(key(start, calendar) == "2026-03-08")
        #expect(builds == 4)
        for offset in 1...8 {
            var other = calendar
            other.timeZone = TimeZone(secondsFromGMT: offset * 3600)!
            #expect(key(start, other) == Self.reference(start, calendar: other))
        }
        #expect(builds == 12)
        #expect(key(start, calendar) == "2026-03-08")
        #expect(builds == 13)
    }

    @Test
    func `scan memo invalidates when caller changes time zone`() {
        let date = Date(timeIntervalSince1970: 1_772_956_800)
        var memo = CostUsageLocalDayKeyMemo()
        for zone in Self.zones + Self.zones.reversed() {
            let calendar = Self.calendar(zone)
            #expect(memo.key(for: date, calendar: calendar) == Self.reference(date, calendar: calendar))
        }
    }

    @Test
    func `concurrent time zones and eviction retain independent day keys`() async {
        await withTaskGroup(of: Void.self) { group in
            for offset in -12...14 {
                group.addTask {
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = TimeZone(secondsFromGMT: offset * 3600)!
                    for second in 0..<500 {
                        let date = Date(timeIntervalSince1970: 1_772_956_800 + Double(second * 1800))
                        #expect(CostUsageLocalDay.key(from: date, calendar: calendar)
                            == Self.reference(date, calendar: calendar))
                    }
                }
            }
        }
    }
}
