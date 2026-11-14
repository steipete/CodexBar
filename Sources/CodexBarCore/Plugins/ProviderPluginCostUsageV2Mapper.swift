import Foundation

/// Version 2 preserves server totals and unknown metrics; it never synthesizes idle days.
enum ProviderPluginCostUsageV2Mapper {
    static func map(_ value: any ProviderPluginValue) throws -> CostUsageTokenSnapshot {
        try self.fields(
            value,
            allowed: ["version", "timeZone", "windowStart", "windowEnd", "currency", "historyLabel", "entries"])
        let timeZoneID = try self.string(value, "timeZone")
        guard let timeZone = TimeZone(identifier: timeZoneID) else {
            throw self.invalid("timeZone must be a valid time zone identifier")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let windowStart = try self.string(value, "windowStart")
        let windowEnd = try self.string(value, "windowEnd")
        let start = try self.date(windowStart, calendar: calendar)
        let end = try self.date(windowEnd, calendar: calendar)
        let days = (calendar.dateComponents([.day], from: start, to: end).day ?? -1) + 1
        guard (1...366).contains(days) else { throw self.invalid("window must contain 1 to 366 days") }
        let currency = try self.optionalString(value, "currency")
        if let currency, currency.range(of: "^[A-Z]{3}$", options: .regularExpression) == nil || currency == "XXX" {
            throw self.invalid("currency must be a known three-letter uppercase currency literal")
        }
        guard let entries = value.property("entries"), entries.isArray,
              let countValue = entries.property("length"), countValue.isNumber
        else { throw self.invalid("entries must be an array with at most 366 daily rows") }
        let count = countValue.doubleValue()
        guard count.isFinite, count.rounded(.towardZero) == count, (0...366).contains(count) else {
            throw self.invalid("entries must contain at most 366 daily rows")
        }
        var seen: Set<String> = []
        let daily: [CostUsageDailyReport.Entry] = try (0..<Int(count)).map { index in
            guard let entry = entries.element(at: index), entry.isObject, !entry.isArray else {
                throw self.invalid("entries[\(index)] must be an object")
            }
            try self.fields(entry, allowed: [
                "date", "totalTokens", "inputTokens", "outputTokens", "cacheReadTokens", "cacheCreationTokens",
                "reasoningTokens", "requests", "cost",
            ])
            let key = try self.string(entry, "date")
            let day = try self.date(key, calendar: calendar)
            guard day >= start, day <= end, seen.insert(key).inserted else {
                throw self.invalid("daily dates must be unique and inside the declared window")
            }
            let input = try self.integer(entry, "inputTokens")
            let output = try self.integer(entry, "outputTokens")
            let total = try self.integer(entry, "totalTokens")
            let cost = try self.cost(entry)
            guard cost == nil || currency != nil else { throw self.invalid("cost requires currency") }
            // Total is authoritative. Cache read/write counts may overlap input, so never add them.
            return try CostUsageDailyReport.Entry(
                date: key,
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: self.integer(entry, "cacheReadTokens"),
                cacheCreationTokens: self.integer(entry, "cacheCreationTokens"),
                reasoningTokens: self.integer(entry, "reasoningTokens"),
                totalTokens: total,
                requestCount: self.integer(entry, "requests"),
                costUSD: cost,
                modelsUsed: nil,
                modelBreakdowns: nil)
        }.sorted { $0.date < $1.date }
        return try CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: self.sum(daily.map(\.totalTokens)),
            last30DaysCostUSD: self.sumCosts(daily.map(\.costUSD)),
            last30DaysRequests: self.sum(daily.map(\.requestCount)),
            currencyCode: currency ?? "XXX",
            historyDays: days,
            historyLabel: self.optionalString(value, "historyLabel"),
            costProvenance: daily.contains { $0.costUSD != nil } ? .vendorMetered : .unknown,
            daily: daily,
            dailyHistory: CostUsageDailyHistory(
                timeZoneIdentifier: timeZoneID,
                windowStart: windowStart,
                windowEnd: windowEnd),
            updatedAt: end)
    }

    private static func fields(_ value: any ProviderPluginValue, allowed: Set<String>) throws {
        guard try value.propertyNames().allSatisfy(allowed.contains) else {
            throw self.invalid("unsupported field")
        }
    }

    private static func invalid(_ message: String) -> ProviderPluginError {
        .invalidSnapshot("costUsage v2: \(message)")
    }

    private static func optionalString(_ value: any ProviderPluginValue, _ key: String) throws -> String? {
        guard let field = value.property(key), !field.isUndefined, !field.isNull else { return nil }
        guard field.isString, !field.stringValue().isEmpty, field.stringValue().utf8.count <= 256 else {
            throw self.invalid("\(key) must be a nonempty string of at most 256 bytes")
        }
        return field.stringValue()
    }

    private static func string(_ value: any ProviderPluginValue, _ key: String) throws -> String {
        guard let result = try self.optionalString(value, key) else { throw self.invalid("\(key) is required") }
        return result
    }

    private static func date(_ key: String, calendar: Calendar) throws -> Date {
        let parts = key.split(separator: "-")
        guard key.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil,
              parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              CostUsageLocalDay.key(from: date, calendar: calendar) == key
        else { throw self.invalid("dates must be valid YYYY-MM-DD calendar dates") }
        return date
    }

    private static func integer(_ value: any ProviderPluginValue, _ key: String) throws -> Int? {
        guard let field = value.property(key), !field.isUndefined, !field.isNull else { return nil }
        if field.isString {
            let raw = field.stringValue()
            guard raw.range(of: "^(0|[1-9][0-9]*)$", options: .regularExpression) != nil,
                  let result = Int(raw), result >= 0
            else { throw self.invalid("\(key) must be an exact nonnegative integer") }
            return result
        }
        guard field.isNumber
        else { throw self.invalid("\(key) must be a safe nonnegative integer or a decimal integer string") }
        let number = field.doubleValue()
        guard number.isFinite, number >= 0, number.rounded(.towardZero) == number,
              number <= 9_007_199_254_740_991
        else { throw self.invalid("\(key) must be a safe nonnegative integer or a decimal integer string") }
        return Int(number)
    }

    private static func cost(_ value: any ProviderPluginValue) throws -> Double? {
        guard let field = value.property("cost"), !field.isUndefined, !field.isNull else { return nil }
        guard field.isNumber else { throw self.invalid("cost must be a finite nonnegative number") }
        let number = field.doubleValue()
        guard number.isFinite, number >= 0 else {
            throw self.invalid("cost must be a finite nonnegative number")
        }
        return number
    }

    private static func sum(_ values: [Int?]) throws -> Int? {
        let known = values.compactMap(\.self)
        guard !known.isEmpty else { return nil }
        guard let result = CheckedSum.integers(known) else {
            throw self.invalid("integer total overflowed")
        }
        return known.count == values.count ? result : nil
    }

    private static func sumCosts(_ values: [Double?]) throws -> Double? {
        let known = values.compactMap(\.self)
        guard !known.isEmpty else { return nil }
        let result = known.reduce(0, +)
        guard result.isFinite else { throw self.invalid("cost total overflowed") }
        return known.count == values.count ? result : nil
    }
}
