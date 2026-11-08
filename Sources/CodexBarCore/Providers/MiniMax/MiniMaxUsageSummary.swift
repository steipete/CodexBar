import Foundation

public struct MiniMaxUsageSummary: Sendable, Equatable {
    public struct Day: Sendable, Equatable {
        public let date: String
        public let totalTokens: Int?
        public let inputTokens: Int?
        public let outputTokens: Int?
        public let cacheReadTokens: Int?
        public let cacheWriteTokens: Int?
    }

    public let days: [Day]
    public let lastUpdateTime: String?

    func today(now: Date) -> Day? {
        let key = Self.dateKey(now)
        return self.days.first { $0.date == key }
    }

    func last30Days(now: Date) -> [Day] {
        let calendar = Self.chinaCalendar
        let end = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -29, to: end) else { return [] }
        return self.days.filter { day in
            guard let date = Self.date(day.date) else { return false }
            return date >= start && date <= end
        }
    }

    func last30DaysTokens(now: Date) -> Int? {
        let days = self.last30Days(now: now)
        guard !days.isEmpty else { return nil }
        var total = 0
        for day in days {
            guard let tokens = day.totalTokens else { return nil }
            let addition = total.addingReportingOverflow(tokens)
            guard !addition.overflow else { return nil }
            total = addition.partialValue
        }
        return total
    }

    func detailSection(now: Date) -> ProviderDetailSection? {
        let days = self.last30Days(now: now)
        guard !days.isEmpty else { return nil }
        let today = self.today(now: now)
        var rows: [ProviderDetailSection.Row] = [
            .makeRow(label: "Today tokens", value: Self.display(today?.totalTokens)),
            .makeRow(label: "Input tokens", value: Self.display(today?.inputTokens)),
            .makeRow(label: "Output tokens", value: Self.display(today?.outputTokens)),
            .makeRow(
                label: "Cache read tokens",
                value: Self.display(today?.cacheReadTokens),
                secondaryValue: "Included in input tokens"),
            .makeRow(
                label: "Cache write tokens",
                value: Self.display(today?.cacheWriteTokens)),
            .makeRow(
                label: "30d tokens",
                value: Self.display(self.last30DaysTokens(now: now)),
                secondaryValue: days.count < 30 ? "\(days.count) reported days" : nil),
        ]
        if let lastUpdateTime = self.lastUpdateTime {
            rows.append(.makeRow(label: "Data updated", value: lastUpdateTime))
        }
        let points = days.compactMap { day -> (label: String, value: Double)? in
            guard let tokens = day.totalTokens else { return nil }
            return (day.date, Double(tokens))
        }
        return .makeSection(
            title: "Tokens",
            rows: rows,
            chart: points.isEmpty ? nil : .makeChart(title: "Daily tokens", unit: "tokens", points: points))
    }

    fileprivate static var chinaCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    fileprivate static func date(_ key: String) -> Date? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        let calendar = Self.chinaCalendar
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard components.year == year, components.month == month, components.day == day,
              Self.dateKey(date) == key
        else { return nil }
        return date
    }

    fileprivate static func dateKey(_ date: Date) -> String {
        let components = Self.chinaCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }

    private static func display(_ value: Int?) -> String {
        value?.formatted() ?? "—"
    }
}

enum MiniMaxUsageSummaryParser {
    static func parse(data: Data, now: Date = Date()) throws -> MiniMaxUsageSummary {
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(ResponseEnvelope.self, from: data)
        if let status = envelope.baseResp?.statusCode, status != 0 {
            let message = envelope.baseResp?.statusMessage?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            if status == 1004 || message.contains("cookie") || message.contains("login")
                || message.contains("log in") || message == "invalid api key"
            {
                throw MiniMaxUsageError.invalidCredentials
            }
            throw MiniMaxUsageError.apiError("status_code \(status)")
        }

        let payload = try decoder.decode(Payload.self, from: data)
        let today = MiniMaxUsageSummary.chinaCalendar.startOfDay(for: now)
        var daysByDate: [String: MiniMaxUsageSummary.Day] = [:]
        var conflictingDates: Set<String> = []
        for record in payload.days {
            guard let day = record.day,
                  let date = MiniMaxUsageSummary.date(day.date), date <= today,
                  !conflictingDates.contains(day.date)
            else { continue }
            if let existing = daysByDate[day.date], existing != day {
                // Conflicting rows must not silently reduce a period's reported total.
                daysByDate[day.date] = MiniMaxUsageSummary.Day(
                    date: day.date,
                    totalTokens: nil,
                    inputTokens: nil,
                    outputTokens: nil,
                    cacheReadTokens: nil,
                    cacheWriteTokens: nil)
                conflictingDates.insert(day.date)
            } else {
                daysByDate[day.date] = day
            }
        }
        return MiniMaxUsageSummary(
            days: daysByDate.values.sorted { $0.date < $1.date },
            lastUpdateTime: payload.lastUpdateTime)
    }

    private struct ResponseEnvelope: Decodable {
        let baseResp: MiniMaxBaseResponse?

        private enum CodingKeys: String, CodingKey {
            case baseResp = "base_resp"
        }
    }

    private struct Payload: Decodable {
        let days: [DayPayload]
        let lastUpdateTime: String?

        private enum CodingKeys: String, CodingKey {
            case days = "date_model_usage"
            case lastUpdateTime = "last_update_time"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.days = try container.decodeIfPresent([DayPayload].self, forKey: .days) ?? []
            let updated = try? container.decodeIfPresent(String.self, forKey: .lastUpdateTime)
            let trimmed = updated?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.lastUpdateTime = trimmed.flatMap { $0.isEmpty ? nil : String($0.prefix(128)) }
        }
    }

    private struct DayPayload: Decodable {
        let day: MiniMaxUsageSummary.Day?

        private enum CodingKeys: String, CodingKey {
            case date
            case total = "total_token"
            case input = "total_input_token"
            case output = "total_output_token"
            case cacheRead = "total_cache_read_token"
            case cacheWrite = "total_cache_create_token"
        }

        init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self),
                  let rawDate = try? container.decode(String.self, forKey: .date)
            else {
                self.day = nil
                return
            }
            func count(_ key: CodingKeys) -> Int? {
                let number = (try? container.decodeIfPresent(Int.self, forKey: key))
                    ?? (try? container.decodeIfPresent(String.self, forKey: key))
                    .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                guard let number, number >= 0 else { return nil }
                return number
            }
            self.day = MiniMaxUsageSummary.Day(
                date: rawDate.trimmingCharacters(in: .whitespacesAndNewlines),
                totalTokens: count(.total),
                inputTokens: count(.input),
                outputTokens: count(.output),
                cacheReadTokens: count(.cacheRead),
                cacheWriteTokens: count(.cacheWrite))
        }
    }
}
