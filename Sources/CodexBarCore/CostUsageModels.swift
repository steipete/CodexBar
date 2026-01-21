import Foundation

public struct CostUsageTokenSnapshot: Sendable, Equatable {
    public let sessionTokens: Int?
    public let sessionCostUSD: Double?
    public let last30DaysTokens: Int?
    public let last30DaysCostUSD: Double?
    public let daily: [CostUsageDailyReport.Entry]
    public let updatedAt: Date

    public init(
        sessionTokens: Int?,
        sessionCostUSD: Double?,
        last30DaysTokens: Int?,
        last30DaysCostUSD: Double?,
        daily: [CostUsageDailyReport.Entry],
        updatedAt: Date)
    {
        self.sessionTokens = sessionTokens
        self.sessionCostUSD = sessionCostUSD
        self.last30DaysTokens = last30DaysTokens
        self.last30DaysCostUSD = last30DaysCostUSD
        self.daily = daily
        self.updatedAt = updatedAt
    }
}

public struct CostUsageDailyReport: Sendable, Decodable {
    public struct ModelBreakdown: Sendable, Decodable, Equatable {
        public let modelName: String
        public let costUSD: Double?

        private enum CodingKeys: String, CodingKey {
            case modelName
            case costUSD
            case cost
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.modelName = try container.decode(String.self, forKey: .modelName)
            self.costUSD =
                try container.decodeIfPresent(Double.self, forKey: .costUSD)
                ?? container.decodeIfPresent(Double.self, forKey: .cost)
        }

        public init(modelName: String, costUSD: Double?) {
            self.modelName = modelName
            self.costUSD = costUSD
        }
    }

    public struct Entry: Sendable, Decodable, Equatable {
        public let date: String
        public let inputTokens: Int?
        public let cacheReadTokens: Int?
        public let cacheCreationTokens: Int?
        public let outputTokens: Int?
        public let totalTokens: Int?
        public let costUSD: Double?
        public let modelsUsed: [String]?
        public let modelBreakdowns: [ModelBreakdown]?

        private enum CodingKeys: String, CodingKey {
            case date
            case inputTokens
            case cacheReadTokens
            case cacheCreationTokens
            case cacheReadInputTokens
            case cacheCreationInputTokens
            case outputTokens
            case totalTokens
            case costUSD
            case totalCost
            case modelsUsed
            case models
            case modelBreakdowns
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.date = try container.decode(String.self, forKey: .date)
            self.inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens)
            self.cacheReadTokens =
                try container.decodeIfPresent(Int.self, forKey: .cacheReadTokens)
                ?? container.decodeIfPresent(Int.self, forKey: .cacheReadInputTokens)
            self.cacheCreationTokens =
                try container.decodeIfPresent(Int.self, forKey: .cacheCreationTokens)
                ?? container.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens)
            self.outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens)
            self.totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
            self.costUSD =
                try container.decodeIfPresent(Double.self, forKey: .costUSD)
                ?? container.decodeIfPresent(Double.self, forKey: .totalCost)
            self.modelsUsed = Self.decodeModelsUsed(from: container)
            self.modelBreakdowns = try container.decodeIfPresent([ModelBreakdown].self, forKey: .modelBreakdowns)
        }

        public init(
            date: String,
            inputTokens: Int?,
            outputTokens: Int?,
            cacheReadTokens: Int? = nil,
            cacheCreationTokens: Int? = nil,
            totalTokens: Int?,
            costUSD: Double?,
            modelsUsed: [String]?,
            modelBreakdowns: [ModelBreakdown]?)
        {
            self.date = date
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheCreationTokens = cacheCreationTokens
            self.totalTokens = totalTokens
            self.costUSD = costUSD
            self.modelsUsed = modelsUsed
            self.modelBreakdowns = modelBreakdowns
        }

        private static func decodeModelsUsed(from container: KeyedDecodingContainer<CodingKeys>) -> [String]? {
            func decodeStringList(_ key: CodingKeys) -> [String]? {
                (try? container.decodeIfPresent([String].self, forKey: key)).flatMap(\.self)
            }

            if let modelsUsed = decodeStringList(.modelsUsed) { return modelsUsed }
            if let models = decodeStringList(.models) { return models }

            guard container.contains(.models) else { return nil }

            guard let modelMap = try? container.nestedContainer(keyedBy: CostUsageAnyCodingKey.self, forKey: .models)
            else { return nil }

            let modelNames = modelMap.allKeys.map(\.stringValue).sorted()
            return modelNames.isEmpty ? nil : modelNames
        }
    }

    public struct Summary: Sendable, Decodable, Equatable {
        public let totalInputTokens: Int?
        public let totalOutputTokens: Int?
        public let cacheReadTokens: Int?
        public let cacheCreationTokens: Int?
        public let totalTokens: Int?
        public let totalCostUSD: Double?

        private enum CodingKeys: String, CodingKey {
            case totalInputTokens
            case totalOutputTokens
            case cacheReadTokens
            case cacheCreationTokens
            case totalCacheReadTokens
            case totalCacheCreationTokens
            case totalTokens
            case totalCostUSD
            case totalCost
        }

        public init(
            totalInputTokens: Int?,
            totalOutputTokens: Int?,
            cacheReadTokens: Int? = nil,
            cacheCreationTokens: Int? = nil,
            totalTokens: Int?,
            totalCostUSD: Double?)
        {
            self.totalInputTokens = totalInputTokens
            self.totalOutputTokens = totalOutputTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheCreationTokens = cacheCreationTokens
            self.totalTokens = totalTokens
            self.totalCostUSD = totalCostUSD
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.totalInputTokens = try container.decodeIfPresent(Int.self, forKey: .totalInputTokens)
            self.totalOutputTokens = try container.decodeIfPresent(Int.self, forKey: .totalOutputTokens)
            self.cacheReadTokens =
                try container.decodeIfPresent(Int.self, forKey: .cacheReadTokens)
                ?? container.decodeIfPresent(Int.self, forKey: .totalCacheReadTokens)
            self.cacheCreationTokens =
                try container.decodeIfPresent(Int.self, forKey: .cacheCreationTokens)
                ?? container.decodeIfPresent(Int.self, forKey: .totalCacheCreationTokens)
            self.totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
            self.totalCostUSD =
                try container.decodeIfPresent(Double.self, forKey: .totalCostUSD)
                ?? container.decodeIfPresent(Double.self, forKey: .totalCost)
        }
    }

    public let data: [Entry]
    public let summary: Summary?

    private enum CodingKeys: String, CodingKey {
        case type
        case data
        case summary
        case daily
        case totals
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if container.contains(.type) {
            _ = try container.decode(String.self, forKey: .type)
            self.data = try container.decode([Entry].self, forKey: .data)
            self.summary = try container.decodeIfPresent(Summary.self, forKey: .summary)
            return
        }

        self.data = try container.decode([Entry].self, forKey: .daily)
        if container.contains(.totals) {
            let totals = try container.decode(CostUsageLegacyTotals.self, forKey: .totals)
            self.summary = Summary(
                totalInputTokens: totals.totalInputTokens,
                totalOutputTokens: totals.totalOutputTokens,
                cacheReadTokens: totals.cacheReadTokens,
                cacheCreationTokens: totals.cacheCreationTokens,
                totalTokens: totals.totalTokens,
                totalCostUSD: totals.totalCost)
        } else {
            self.summary = nil
        }
    }

    public init(data: [Entry], summary: Summary?) {
        self.data = data
        self.summary = summary
    }
}

public struct CostUsageSessionReport: Sendable, Decodable {
    public struct Entry: Sendable, Decodable, Equatable {
        public let session: String
        public let inputTokens: Int?
        public let outputTokens: Int?
        public let totalTokens: Int?
        public let costUSD: Double?
        public let lastActivity: String?

        private enum CodingKeys: String, CodingKey {
            case session
            case sessionId
            case inputTokens
            case outputTokens
            case totalTokens
            case costUSD
            case totalCost
            case lastActivity
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.session =
                try container.decodeIfPresent(String.self, forKey: .session)
                ?? container.decode(String.self, forKey: .sessionId)
            self.inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens)
            self.outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens)
            self.totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
            self.costUSD =
                try container.decodeIfPresent(Double.self, forKey: .costUSD)
                ?? container.decodeIfPresent(Double.self, forKey: .totalCost)
            self.lastActivity = try container.decodeIfPresent(String.self, forKey: .lastActivity)
        }
    }

    public struct Summary: Sendable, Decodable, Equatable {
        public let totalCostUSD: Double?

        private enum CodingKeys: String, CodingKey {
            case totalCostUSD
            case totalCost
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.totalCostUSD =
                try container.decodeIfPresent(Double.self, forKey: .totalCostUSD)
                ?? container.decodeIfPresent(Double.self, forKey: .totalCost)
        }
    }

    public let data: [Entry]
    public let summary: Summary?

    private enum CodingKeys: String, CodingKey {
        case type
        case data
        case summary
        case sessions
        case totals
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.type) {
            _ = try container.decode(String.self, forKey: .type)
            self.data = try container.decode([Entry].self, forKey: .data)
            self.summary = try container.decodeIfPresent(Summary.self, forKey: .summary)
            return
        }

        self.data = try container.decode([Entry].self, forKey: .sessions)
        self.summary = try container.decodeIfPresent(Summary.self, forKey: .totals)
    }
}

public struct CostUsageMonthlyReport: Sendable, Decodable {
    public struct Entry: Sendable, Decodable, Equatable {
        public let month: String
        public let totalTokens: Int?
        public let costUSD: Double?

        private enum CodingKeys: String, CodingKey {
            case month
            case totalTokens
            case costUSD
            case totalCost
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.month = try container.decode(String.self, forKey: .month)
            self.totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
            self.costUSD =
                try container.decodeIfPresent(Double.self, forKey: .costUSD)
                ?? container.decodeIfPresent(Double.self, forKey: .totalCost)
        }
    }

    public struct Summary: Sendable, Decodable, Equatable {
        public let totalTokens: Int?
        public let totalCostUSD: Double?

        private enum CodingKeys: String, CodingKey {
            case totalTokens
            case costUSD
            case totalCostUSD
            case totalCost
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
            self.totalCostUSD =
                try container.decodeIfPresent(Double.self, forKey: .totalCostUSD)
                ?? container.decodeIfPresent(Double.self, forKey: .costUSD)
                ?? container.decodeIfPresent(Double.self, forKey: .totalCost)
        }
    }

    public let data: [Entry]
    public let summary: Summary?

    private enum CodingKeys: String, CodingKey {
        case type
        case data
        case summary
        case monthly
        case totals
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if container.contains(.type) {
            _ = try container.decode(String.self, forKey: .type)
            self.data = try container.decode([Entry].self, forKey: .data)
            self.summary = try container.decodeIfPresent(Summary.self, forKey: .summary)
            return
        }

        self.data = try container.decode([Entry].self, forKey: .monthly)
        self.summary = try container.decodeIfPresent(Summary.self, forKey: .totals)
    }
}

private struct CostUsageLegacyTotals: Sendable, Decodable {
    let totalInputTokens: Int?
    let totalOutputTokens: Int?
    let cacheReadTokens: Int?
    let cacheCreationTokens: Int?
    let totalTokens: Int?
    let totalCost: Double?

    private enum CodingKeys: String, CodingKey {
        case totalInputTokens
        case totalOutputTokens
        case cacheReadTokens
        case cacheCreationTokens
        case totalCacheReadTokens
        case totalCacheCreationTokens
        case totalTokens
        case totalCost
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.totalInputTokens = try container.decodeIfPresent(Int.self, forKey: .totalInputTokens)
        self.totalOutputTokens = try container.decodeIfPresent(Int.self, forKey: .totalOutputTokens)
        self.cacheReadTokens =
            try container.decodeIfPresent(Int.self, forKey: .cacheReadTokens)
            ?? container.decodeIfPresent(Int.self, forKey: .totalCacheReadTokens)
        self.cacheCreationTokens =
            try container.decodeIfPresent(Int.self, forKey: .cacheCreationTokens)
            ?? container.decodeIfPresent(Int.self, forKey: .totalCacheCreationTokens)
        self.totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
        self.totalCost = try container.decodeIfPresent(Double.self, forKey: .totalCost)
    }
}

private struct CostUsageAnyCodingKey: CodingKey {
    var intValue: Int?
    var stringValue: String

    init?(intValue: Int) {
        self.intValue = intValue
        self.stringValue = "\(intValue)"
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }
}

enum CostUsageDateParser {
    static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: trimmed) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: trimmed) { return d }

        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone.current
        day.dateFormat = "yyyy-MM-dd"
        if let d = day.date(from: trimmed) { return d }

        let monthDayYear = DateFormatter()
        monthDayYear.locale = Locale(identifier: "en_US_POSIX")
        monthDayYear.timeZone = TimeZone.current
        monthDayYear.dateFormat = "MMM d, yyyy"
        if let d = monthDayYear.date(from: trimmed) { return d }

        return nil
    }

    static func parseMonth(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let monthYear = DateFormatter()
        monthYear.locale = Locale(identifier: "en_US_POSIX")
        monthYear.timeZone = TimeZone.current
        monthYear.dateFormat = "MMM yyyy"
        if let d = monthYear.date(from: trimmed) { return d }

        let fullMonthYear = DateFormatter()
        fullMonthYear.locale = Locale(identifier: "en_US_POSIX")
        fullMonthYear.timeZone = TimeZone.current
        fullMonthYear.dateFormat = "MMMM yyyy"
        if let d = fullMonthYear.date(from: trimmed) { return d }

        let ym = DateFormatter()
        ym.locale = Locale(identifier: "en_US_POSIX")
        ym.timeZone = TimeZone.current
        ym.dateFormat = "yyyy-MM"
        if let d = ym.date(from: trimmed) { return d }

        return nil
    }
}
