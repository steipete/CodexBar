import Foundation

/// Explicitly requested numeric history. No account, model, project, session, or path fields cross SSH.
public struct CodexCostDailySummary: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public let date: String
        public let totalTokens: Int?
        public let costUSD: Double?
        public let incompleteRequestCount: Int
        public let coverage: CostUsageCoverageCounts

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case date, totalTokens, costUSD, incompleteRequestCount, coverage
        }

        init(_ entry: CostUsageDailyReport.Entry) {
            self.date = entry.date
            self.totalTokens = entry.totalTokens
            self.costUSD = entry.costUSD
            self.incompleteRequestCount = entry.incompleteRequestCount
            self.coverage = entry.coverageCounts
        }

        public init(from decoder: Decoder) throws {
            try DailySummaryFields.validate(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.date = try container.decode(String.self, forKey: .date)
            self.totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
            self.costUSD = try container.decodeIfPresent(Double.self, forKey: .costUSD)
            self.incompleteRequestCount = try container.decode(Int.self, forKey: .incompleteRequestCount)
            let coverageDecoder = try container.superDecoder(forKey: .coverage)
            try DailySummaryFields.validate(
                coverageDecoder, allowed: ["priced", "unpriced", "unmetered", "estimated"])
            self.coverage = try CostUsageCoverageCounts(from: coverageDecoder)
        }

        var nativeEntry: CostUsageDailyReport.Entry {
            .init(
                date: self.date,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: self.totalTokens,
                costUSD: self.costUSD,
                modelsUsed: nil,
                modelBreakdowns: nil,
                unpricedRequestCount: self.coverage.unpriced,
                unmeteredRequestCount: self.coverage.unmetered,
                estimatedRequestCount: self.coverage.estimated,
                pricedRequestCount: self.coverage.priced,
                incompleteRequestCount: self.incompleteRequestCount)
        }
    }

    public let schemaVersion: Int
    public let kind: String
    public let provider: String
    public let updatedAt: Date
    public let bucketTimeZone: String
    public let currencyCode: String
    public let historyDays: Int
    public let historyCoverageIsEstablished: Bool
    public let historyScanIsPartial: Bool
    public let costProvenance: CostProvenance
    public let daily: [Entry]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, kind, provider, updatedAt, bucketTimeZone, currencyCode, historyDays
        case historyCoverageIsEstablished, historyScanIsPartial, costProvenance, daily
    }

    public init(snapshot: CostUsageTokenSnapshot, calendar: Calendar) throws {
        self.schemaVersion = 1
        self.kind = "daily"
        self.provider = "codex"
        self.updatedAt = snapshot.updatedAt
        self.bucketTimeZone = calendar.timeZone.identifier
        self.currencyCode = snapshot.currencyCode
        self.historyDays = snapshot.historyDays
        self.historyCoverageIsEstablished = snapshot.historyCoverageIsEstablished
        self.historyScanIsPartial = snapshot.historyScanIsPartial
        self.costProvenance = snapshot.costProvenance
        self.daily = snapshot.daily.map(Entry.init).sorted { $0.date < $1.date }
        try self.validate(historyDays: self.historyDays, bucketTimeZone: self.bucketTimeZone)
    }

    public init(from decoder: Decoder) throws {
        try DailySummaryFields.validate(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.kind = try container.decode(String.self, forKey: .kind)
        self.provider = try container.decode(String.self, forKey: .provider)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.bucketTimeZone = try container.decode(String.self, forKey: .bucketTimeZone)
        self.currencyCode = try container.decode(String.self, forKey: .currencyCode)
        self.historyDays = try container.decode(Int.self, forKey: .historyDays)
        self.historyCoverageIsEstablished = try container.decode(Bool.self, forKey: .historyCoverageIsEstablished)
        self.historyScanIsPartial = try container.decode(Bool.self, forKey: .historyScanIsPartial)
        self.costProvenance = try container.decode(CostProvenance.self, forKey: .costProvenance)
        self.daily = try container.decode([Entry].self, forKey: .daily)
    }

    /// Validate before scanning or constructing a remote command; never silently fall back to host-local time.
    public static func calendar(bucketTimeZone: String) throws -> Calendar {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/_+-:")
        guard !bucketTimeZone.isEmpty, bucketTimeZone.utf8.count <= 128,
              bucketTimeZone.unicodeScalars.allSatisfy(allowed.contains),
              let zone = TimeZone(identifier: bucketTimeZone)
        else { throw RemoteCodexCostError.invalidReport }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    public func validate(historyDays: Int, bucketTimeZone: String) throws {
        let calendar = try Self.calendar(bucketTimeZone: bucketTimeZone)
        guard self.schemaVersion == 1, self.kind == "daily", self.provider == "codex",
              (1...365).contains(historyDays), self.historyDays == historyDays,
              self.bucketTimeZone == calendar.timeZone.identifier, self.currencyCode == "USD",
              self.costProvenance == .listPriceEstimate || self.costProvenance == .unknown,
              self.updatedAt.timeIntervalSince1970.isFinite,
              (0...253_402_300_799).contains(self.updatedAt.timeIntervalSince1970),
              self.daily.count <= historyDays
        else { throw RemoteCodexCostError.invalidReport }
        let end = calendar.startOfDay(for: self.updatedAt)
        guard let start = calendar.date(byAdding: .day, value: -(historyDays - 1), to: end) else {
            throw RemoteCodexCostError.invalidReport
        }
        let startKey = CostUsageLocalDay.key(from: start, calendar: calendar)
        let endKey = CostUsageLocalDay.key(from: end, calendar: calendar)
        var previousKey = ""
        var tokens = 0
        var coverage = 0
        var incomplete = 0
        var cost = 0.0
        for entry in self.daily {
            guard entry.date.utf8.count == 10,
                  let date = CostUsageLocalDay.date(fromKey: entry.date, calendar: calendar),
                  CostUsageLocalDay.key(from: date, calendar: calendar) == entry.date,
                  entry.date >= startKey, entry.date <= endKey, entry.date > previousKey
            else { throw RemoteCodexCostError.invalidReport }
            previousKey = entry.date
            try Self.add(entry.totalTokens ?? 0, to: &tokens)
            try Self.add(entry.incompleteRequestCount, to: &incomplete)
            for count in [
                entry.coverage.priced,
                entry.coverage.unpriced,
                entry.coverage.unmetered,
                entry.coverage.estimated,
            ] {
                try Self.add(count, to: &coverage)
            }
            if let amount = entry.costUSD {
                guard amount.isFinite, amount >= 0 else { throw RemoteCodexCostError.invalidReport }
                cost += amount
                guard cost.isFinite else { throw RemoteCodexCostError.invalidReport }
            }
        }
    }

    /// Retain the source timestamp. The receiver may refresh after midnight, but must not re-date old buckets.
    public func tokenSnapshot() throws -> CostUsageTokenSnapshot {
        try self.validate(historyDays: self.historyDays, bucketTimeZone: self.bucketTimeZone)
        let calendar = try Self.calendar(bucketTimeZone: self.bucketTimeZone)
        let today = CostUsageLocalDay.key(from: self.updatedAt, calendar: calendar)
        let current = self.daily.first { $0.date == today }
        let fullyScanned = self.historyCoverageIsEstablished && !self.historyScanIsPartial
        guard let windowStart = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: self.updatedAt))
        else {
            throw RemoteCodexCostError.invalidReport
        }
        let windowKey = CostUsageLocalDay.key(from: windowStart, calendar: calendar)
        let recent = self.daily.filter { $0.date >= windowKey }
        let knownTokens = recent.allSatisfy { $0.totalTokens != nil }
        let knownCosts = recent.allSatisfy { $0.costUSD != nil }
        let hasKnownHistory = !recent.isEmpty || fullyScanned
        return CostUsageTokenSnapshot(
            sessionTokens: current?.totalTokens ?? (current == nil && fullyScanned ? 0 : nil),
            sessionCostUSD: current?.costUSD ?? (current == nil && fullyScanned ? 0 : nil),
            last30DaysTokens: knownTokens && hasKnownHistory ? recent.reduce(0) { $0 + ($1.totalTokens ?? 0) } : nil,
            last30DaysCostUSD: knownCosts && hasKnownHistory ? recent.reduce(0) { $0 + ($1.costUSD ?? 0) } : nil,
            currencyCode: self.currencyCode,
            historyDays: self.historyDays,
            historyCoverageIsEstablished: self.historyCoverageIsEstablished,
            historyScanIsPartial: self.historyScanIsPartial,
            costProvenance: self.costProvenance,
            daily: self.daily.map(\.nativeEntry),
            updatedAt: self.updatedAt)
    }

    private static func add(_ count: Int, to total: inout Int) throws {
        let result = total.addingReportingOverflow(count)
        guard count >= 0, !result.overflow else { throw RemoteCodexCostError.invalidReport }
        total = result.partialValue
    }
}

private struct DailySummaryFields: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }

    static func validate(_ decoder: Decoder, allowed: [String]) throws {
        let container = try decoder.container(keyedBy: Self.self)
        guard Set(container.allKeys.map(\.stringValue)).isSubset(of: Set(allowed)) else {
            throw RemoteCodexCostError.invalidReport
        }
    }
}
