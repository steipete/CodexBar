import Foundation

/// Usage/spend history sourced from the Groq console platform API
/// (`/platform/v1/organizations/{org}/activity`). Mirrors the OpenAI API
/// provider's daily cost-history shape so it renders through the shared
/// cost-history inline dashboard.
public struct GroqConsoleUsageSnapshot: Codable, Equatable, Sendable {
    public struct ModelBreakdown: Codable, Equatable, Sendable, Identifiable {
        public let name: String
        public let requests: Int
        public let inputTokens: Int
        public let cachedInputTokens: Int
        public let outputTokens: Int
        public let totalTokens: Int
        public let costUSD: Double

        public var id: String {
            self.name
        }

        public init(
            name: String,
            requests: Int,
            inputTokens: Int,
            cachedInputTokens: Int,
            outputTokens: Int,
            totalTokens: Int,
            costUSD: Double)
        {
            self.name = name
            self.requests = requests
            self.inputTokens = inputTokens
            self.cachedInputTokens = cachedInputTokens
            self.outputTokens = outputTokens
            self.totalTokens = totalTokens
            self.costUSD = costUSD
        }
    }

    public struct DailyBucket: Codable, Equatable, Sendable, Identifiable {
        public let day: String
        public let startTime: Date
        public let endTime: Date
        public let costUSD: Double
        public let requests: Int
        public let inputTokens: Int
        public let cachedInputTokens: Int
        public let outputTokens: Int
        public let totalTokens: Int
        public let models: [ModelBreakdown]

        public var id: String {
            self.day
        }

        public init(
            day: String,
            startTime: Date,
            endTime: Date,
            costUSD: Double,
            requests: Int,
            inputTokens: Int,
            cachedInputTokens: Int,
            outputTokens: Int,
            totalTokens: Int,
            models: [ModelBreakdown])
        {
            self.day = day
            self.startTime = startTime
            self.endTime = endTime
            self.costUSD = costUSD
            self.requests = requests
            self.inputTokens = inputTokens
            self.cachedInputTokens = cachedInputTokens
            self.outputTokens = outputTokens
            self.totalTokens = totalTokens
            self.models = models
        }
    }

    public let daily: [DailyBucket]
    public let updatedAt: Date
    public let historyDays: Int
    public let organizationName: String?
    public let accountEmail: String?

    public init(
        daily: [DailyBucket],
        updatedAt: Date,
        historyDays: Int = 30,
        organizationName: String? = nil,
        accountEmail: String? = nil)
    {
        self.daily = daily.sorted { $0.startTime < $1.startTime }
        self.updatedAt = updatedAt
        self.historyDays = max(1, min(365, historyDays))
        self.organizationName = organizationName
        self.accountEmail = accountEmail
    }

    public var historyWindowPeriodLabel: String {
        self.historyDays == 1 ? "Today" : "Last \(self.historyDays) days"
    }

    public var windowCostUSD: Double {
        self.daily.reduce(0) { $0 + $1.costUSD }
    }

    private var loginMethod: String {
        "Console"
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: self.windowCostUSD,
                limit: 0,
                currencyCode: "USD",
                period: self.historyWindowPeriodLabel,
                updatedAt: self.updatedAt),
            groqConsoleUsage: self,
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .groq,
                accountEmail: self.accountEmail,
                accountOrganization: self.organizationName,
                loginMethod: self.loginMethod))
    }

    public func toCostUsageTokenSnapshot() -> CostUsageTokenSnapshot {
        let daily = self.daily.map { bucket in
            let modelBreakdowns = bucket.models.map {
                CostUsageDailyReport.ModelBreakdown(
                    modelName: $0.name,
                    costUSD: $0.costUSD,
                    totalTokens: $0.totalTokens,
                    requestCount: $0.requests)
            }
            let modelsUsed = bucket.models.map(\.name)
            return CostUsageDailyReport.Entry(
                date: bucket.day,
                inputTokens: bucket.inputTokens,
                outputTokens: bucket.outputTokens,
                cacheReadTokens: bucket.cachedInputTokens,
                cacheCreationTokens: nil,
                totalTokens: bucket.totalTokens,
                requestCount: bucket.requests,
                costUSD: bucket.costUSD,
                modelsUsed: modelsUsed.isEmpty ? nil : modelsUsed,
                modelBreakdowns: modelBreakdowns.isEmpty ? nil : modelBreakdowns)
        }
        let today = self.summary(forLocalDayContaining: self.updatedAt)
        let total = self.summary(days: self.historyDays)
        return CostUsageTokenSnapshot(
            sessionTokens: today.totalTokens,
            sessionCostUSD: today.costUSD,
            sessionRequests: today.requests,
            last30DaysTokens: total.totalTokens,
            last30DaysCostUSD: total.costUSD,
            last30DaysRequests: total.requests,
            historyDays: self.historyDays,
            daily: daily,
            updatedAt: self.updatedAt)
    }

    public var topModels: [ModelBreakdown] {
        var totals: [String: ModelBreakdown] = [:]
        for day in self.daily {
            for model in day.models {
                let existing = totals[model.name]
                totals[model.name] = ModelBreakdown(
                    name: model.name,
                    requests: (existing?.requests ?? 0) + model.requests,
                    inputTokens: (existing?.inputTokens ?? 0) + model.inputTokens,
                    cachedInputTokens: (existing?.cachedInputTokens ?? 0) + model.cachedInputTokens,
                    outputTokens: (existing?.outputTokens ?? 0) + model.outputTokens,
                    totalTokens: (existing?.totalTokens ?? 0) + model.totalTokens,
                    costUSD: (existing?.costUSD ?? 0) + model.costUSD)
            }
        }
        return totals.values.sorted {
            if $0.totalTokens == $1.totalTokens { return $0.name < $1.name }
            return $0.totalTokens > $1.totalTokens
        }
    }

    private struct Summary {
        var costUSD = 0.0
        var requests = 0
        var inputTokens = 0
        var cachedInputTokens = 0
        var outputTokens = 0
        var totalTokens = 0
    }

    private func summary(days: Int) -> Summary {
        self.reduce(self.daily.suffix(max(1, days)))
    }

    private func summary(forLocalDayContaining date: Date) -> Summary {
        let selected = self.daily.filter { bucket in
            CostUsageBucketInterval.contains(date, startTime: bucket.startTime, endTime: bucket.endTime)
        }
        return self.reduce(selected)
    }

    private func reduce(_ buckets: some Sequence<DailyBucket>) -> Summary {
        var summary = Summary()
        for bucket in buckets {
            summary.costUSD += bucket.costUSD
            summary.requests += bucket.requests
            summary.inputTokens += bucket.inputTokens
            summary.cachedInputTokens += bucket.cachedInputTokens
            summary.outputTokens += bucket.outputTokens
            summary.totalTokens += bucket.totalTokens
        }
        return summary
    }
}
