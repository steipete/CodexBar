import Foundation

public enum KimiCodeSessionScanner {
    public static let defaultHistoryDays = 30

    private struct WireEvent: Decodable {
        struct Usage: Decodable {
            let inputOther: Int?
            let inputCacheRead: Int?
            let inputCacheCreation: Int?
            let output: Int?
        }

        let type: String
        let time: Double?
        let model: String?
        let usage: Usage?
        let usageScope: String?
    }

    private struct DayModelKey: Hashable {
        let day: String
        let model: String
    }

    private struct TokenAccumulator {
        var input = 0
        var cacheRead = 0
        var cacheCreation = 0
        var output = 0
        var requests = 0

        mutating func add(_ usage: WireEvent.Usage) -> Bool {
            guard let input = Self.valid(usage.inputOther),
                  let cacheRead = Self.valid(usage.inputCacheRead),
                  let cacheCreation = Self.valid(usage.inputCacheCreation),
                  let output = Self.valid(usage.output),
                  let nextInput = Self.adding(self.input, input),
                  let nextCacheRead = Self.adding(self.cacheRead, cacheRead),
                  let nextCacheCreation = Self.adding(self.cacheCreation, cacheCreation),
                  let nextOutput = Self.adding(self.output, output),
                  let nextRequests = Self.adding(self.requests, 1)
            else {
                return false
            }
            self.input = nextInput
            self.cacheRead = nextCacheRead
            self.cacheCreation = nextCacheCreation
            self.output = nextOutput
            self.requests = nextRequests
            return true
        }

        mutating func merge(_ other: TokenAccumulator) -> Bool {
            guard let nextInput = Self.adding(self.input, other.input),
                  let nextCacheRead = Self.adding(self.cacheRead, other.cacheRead),
                  let nextCacheCreation = Self.adding(self.cacheCreation, other.cacheCreation),
                  let nextOutput = Self.adding(self.output, other.output),
                  let nextRequests = Self.adding(self.requests, other.requests)
            else {
                return false
            }
            self.input = nextInput
            self.cacheRead = nextCacheRead
            self.cacheCreation = nextCacheCreation
            self.output = nextOutput
            self.requests = nextRequests
            return true
        }

        var total: Int? {
            guard let inputAndCacheRead = Self.adding(self.input, self.cacheRead),
                  let withCacheCreation = Self.adding(inputAndCacheRead, self.cacheCreation)
            else {
                return nil
            }
            return Self.adding(withCacheCreation, self.output)
        }

        private static func valid(_ value: Int?) -> Int? {
            guard let value, value >= 0 else { return nil }
            return value
        }

        private static func adding(_ lhs: Int, _ rhs: Int) -> Int? {
            let result = lhs.addingReportingOverflow(rhs)
            return result.overflow ? nil : result.partialValue
        }
    }

    public static func scan(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        historyDays: Int = defaultHistoryDays,
        now: Date = Date(),
        calendar: Calendar = .current) -> CostUsageTokenSnapshot?
    {
        let days = max(1, historyDays)
        let home = KimiSettingsReader.kimiCodeHomeURL(environment: environment)
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: sessions,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else {
            return nil
        }

        let end = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: end) ?? end
        var values: [DayModelKey: TokenAccumulator] = [:]
        let decoder = JSONDecoder()

        while let url = enumerator.nextObject() as? URL {
            guard url.lastPathComponent == "wire.jsonl",
                  url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "agents"
            else {
                continue
            }
            if let modificationDate = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate,
                modificationDate < start
            {
                continue
            }
            guard let data = try? Data(contentsOf: url) else { continue }
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                guard let event = try? decoder.decode(WireEvent.self, from: Data(line)),
                      event.type == "usage.record",
                      event.usageScope == "turn",
                      let time = event.time,
                      time.isFinite,
                      let rawModel = event.model?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !rawModel.isEmpty,
                      let usage = event.usage
                else {
                    continue
                }
                let date = Date(timeIntervalSince1970: time / 1000)
                let day = calendar.startOfDay(for: date)
                guard day >= start, day <= end else { continue }
                let key = DayModelKey(day: CostUsageLocalDay.key(from: day, calendar: calendar), model: rawModel)
                var value = values[key] ?? TokenAccumulator()
                guard value.add(usage) else { continue }
                values[key] = value
            }
        }

        guard !values.isEmpty else { return nil }
        let byDay = Dictionary(grouping: values, by: \.key.day)
        let daily = byDay.keys.sorted().compactMap { day -> CostUsageDailyReport.Entry? in
            let models = (byDay[day] ?? []).sorted { lhs, rhs in
                lhs.key.model.localizedCaseInsensitiveCompare(rhs.key.model) == .orderedAscending
            }
            var total = TokenAccumulator()
            var modelBreakdowns: [CostUsageDailyReport.ModelBreakdown] = []
            for (key, value) in models {
                guard let modelTotal = value.total else { return nil }
                guard total.merge(value) else { return nil }
                modelBreakdowns.append(CostUsageDailyReport.ModelBreakdown(
                    modelName: key.model,
                    costUSD: nil,
                    totalTokens: modelTotal,
                    inputTokens: value.input,
                    cacheReadTokens: value.cacheRead,
                    cacheCreationTokens: value.cacheCreation,
                    outputTokens: value.output,
                    requestCount: value.requests))
            }
            guard let totalTokens = total.total else { return nil }
            return CostUsageDailyReport.Entry(
                date: day,
                inputTokens: total.input,
                outputTokens: total.output,
                cacheReadTokens: total.cacheRead,
                cacheCreationTokens: total.cacheCreation,
                totalTokens: totalTokens,
                requestCount: total.requests,
                costUSD: nil,
                modelsUsed: modelBreakdowns.map(\.modelName),
                modelBreakdowns: modelBreakdowns)
        }
        let totalTokens = self.sum(daily.compactMap(\.totalTokens))
        let totalRequests = self.sum(daily.compactMap(\.requestCount))
        guard let totalTokens, let totalRequests else { return nil }

        return CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            sessionRequests: nil,
            last30DaysTokens: totalTokens,
            last30DaysCostUSD: nil,
            last30DaysRequests: totalRequests,
            currencyCode: "XXX",
            historyDays: days,
            historyCoverageIsEstablished: true,
            historyLabel: "Kimi Code CLI",
            daily: daily,
            updatedAt: now)
    }

    private static func sum(_ values: [Int]) -> Int? {
        var result = 0
        for value in values {
            let addition = result.addingReportingOverflow(value)
            guard !addition.overflow else { return nil }
            result = addition.partialValue
        }
        return result
    }
}
