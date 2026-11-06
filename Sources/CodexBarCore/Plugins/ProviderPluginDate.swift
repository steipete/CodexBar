import Foundation

enum ProviderPluginDate {
    static func nextDailyReset(now: Date, hour: Double, timeZone identifier: String) throws -> Double {
        let invalidReset = ProviderPluginError.script("invalid daily reset time zone or hour")
        guard hour.isFinite, hour.rounded() == hour, (0...23).contains(hour),
              let timeZone = TimeZone(identifier: identifier)
        else {
            throw invalidReset
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        func reset(on date: Date) throws -> Date {
            var components = calendar.dateComponents([.era, .year, .month, .day], from: date)
            components.hour = Int(hour)
            components.minute = 0
            components.second = 0
            guard let result = calendar.date(from: components) else { throw invalidReset }
            return result
        }

        var candidate = try reset(on: now)
        if candidate <= now {
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            else { throw invalidReset }
            candidate = try reset(on: tomorrow)
        }
        return candidate.timeIntervalSince1970 * 1000
    }

    static func addMonths(milliseconds: Double, months: Double, timeZone identifier: String) throws -> Double {
        guard milliseconds.isFinite, abs(milliseconds) <= 8_640_000_000_000_000,
              months.isFinite, months.rounded() == months, abs(months) <= 120_000,
              let timeZone = TimeZone(identifier: identifier)
        else {
            throw ProviderPluginError.script("invalid date, calendar month offset, or time zone")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let result = calendar.date(
            byAdding: .month, value: Int(months), to: Date(timeIntervalSince1970: milliseconds / 1000)),
            abs(result.timeIntervalSince1970) <= 8_640_000_000_000
        else {
            throw ProviderPluginError.script("calendar month result is out of range")
        }
        return result.timeIntervalSince1970 * 1000
    }
}
