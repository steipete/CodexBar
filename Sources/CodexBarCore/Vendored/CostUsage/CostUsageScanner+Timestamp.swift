import Foundation

private final class CostUsageISO8601FormatterBox: @unchecked Sendable {
    let lock = NSLock()
    let withFractional: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    let plain: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt
    }()
}

private enum CostUsageTimestampParser {
    static let box = CostUsageISO8601FormatterBox()

    static func parseISO(_ text: String) -> Date? {
        self.box.lock.lock()
        defer { self.box.lock.unlock() }
        return self.box.withFractional.date(from: text) ?? self.box.plain.date(from: text)
    }
}

extension CostUsageScanner {
    static func dateFromTimestamp(_ text: String) -> Date? {
        CostUsageTimestampParser.parseISO(text)
    }

    static func dayKeyFromTimestamp(_ text: String) -> String? {
        let bytes = Array(text.utf8)
        guard bytes.count >= 20 else { return nil }
        guard bytes[safe: 4] == 45, bytes[safe: 7] == 45 else { return nil }
        guard let year = Self.parse4(bytes, at: 0),
              let month = Self.parse2(bytes, at: 5),
              let day = Self.parse2(bytes, at: 8) else { return nil }

        var hour = 0
        var minute = 0
        var second = 0

        if bytes[safe: 10] == 84 {
            guard bytes.count >= 19 else { return nil }
            guard bytes[safe: 13] == 58, bytes[safe: 16] == 58 else { return nil }
            guard let parsedHour = Self.parse2(bytes, at: 11),
                  let parsedMinute = Self.parse2(bytes, at: 14),
                  let parsedSecond = Self.parse2(bytes, at: 17) else { return nil }
            hour = parsedHour
            minute = parsedMinute
            second = parsedSecond
        }

        var tzIndex: Int?
        var tzSign = 0
        for idx in stride(from: bytes.count - 1, through: 11, by: -1) {
            let byte = bytes[idx]
            if byte == 90 {
                tzIndex = idx
                tzSign = 0
                break
            }
            if byte == 43 {
                tzIndex = idx
                tzSign = 1
                break
            }
            if byte == 45 {
                tzIndex = idx
                tzSign = -1
                break
            }
        }

        guard let tzStart = tzIndex else { return nil }
        var offsetSeconds = 0
        if tzSign != 0 {
            let offsetStart = tzStart + 1
            guard let hours = Self.parse2(bytes, at: offsetStart) else { return nil }
            var minutes = 0
            if bytes.count > offsetStart + 2 {
                if bytes[safe: offsetStart + 2] == 58 {
                    guard let parsedMinutes = Self.parse2(bytes, at: offsetStart + 3) else { return nil }
                    minutes = parsedMinutes
                } else if let parsedMinutes = Self.parse2(bytes, at: offsetStart + 2) {
                    minutes = parsedMinutes
                }
            }
            offsetSeconds = tzSign * ((hours * 3600) + (minutes * 60))
        }

        var comps = DateComponents()
        comps.calendar = Calendar(identifier: .gregorian)
        comps.timeZone = TimeZone(secondsFromGMT: offsetSeconds)
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = second

        guard let date = comps.date else { return nil }
        let local = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let localYear = local.year,
              let localMonth = local.month,
              let localDay = local.day else { return nil }
        return String(format: "%04d-%02d-%02d", localYear, localMonth, localDay)
    }

    static func dayKeyFromParsedISO(_ text: String) -> String? {
        guard let date = CostUsageTimestampParser.parseISO(text) else { return nil }
        return CostUsageDayRange.dayKey(from: date)
    }

    private static func parse2(_ bytes: [UInt8], at index: Int) -> Int? {
        guard let d0 = parseDigit(bytes[safe: index]),
              let d1 = parseDigit(bytes[safe: index + 1]) else { return nil }
        return d0 * 10 + d1
    }

    private static func parse4(_ bytes: [UInt8], at index: Int) -> Int? {
        guard let d0 = parseDigit(bytes[safe: index]),
              let d1 = parseDigit(bytes[safe: index + 1]),
              let d2 = parseDigit(bytes[safe: index + 2]),
              let d3 = parseDigit(bytes[safe: index + 3]) else { return nil }
        return d0 * 1000 + d1 * 100 + d2 * 10 + d3
    }

    private static func parseDigit(_ byte: UInt8?) -> Int? {
        guard let byte else { return nil }
        guard byte >= 48, byte <= 57 else { return nil }
        return Int(byte - 48)
    }
}
