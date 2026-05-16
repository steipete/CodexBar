import Foundation

public struct OpenAIAPIUsageSnapshot: Codable, Equatable, Sendable {
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
        public let lineItems: [LineItemBreakdown]
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
            lineItems: [LineItemBreakdown],
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
            self.lineItems = lineItems
            self.models = models
        }
    }

    public struct LineItemBreakdown: Codable, Equatable, Sendable, Identifiable {
        public let name: String
        public let costUSD: Double

        public var id: String {
            self.name
        }

        public init(name: String, costUSD: Double) {
            self.name = name
            self.costUSD = costUSD
        }
    }

    public struct ModelBreakdown: Codable, Equatable, Sendable, Identifiable {
        public let name: String
        public let requests: Int
        public let inputTokens: Int
        public let cachedInputTokens: Int
        public let outputTokens: Int
        public let totalTokens: Int

        public var id: String {
            self.name
        }

        public init(
            name: String,
            requests: Int,
            inputTokens: Int,
            cachedInputTokens: Int,
            outputTokens: Int,
            totalTokens: Int)
        {
            self.name = name
            self.requests = requests
            self.inputTokens = inputTokens
            self.cachedInputTokens = cachedInputTokens
            self.outputTokens = outputTokens
            self.totalTokens = totalTokens
        }
    }

    public struct Summary: Equatable, Sendable {
        public let costUSD: Double
        public let requests: Int
        public let inputTokens: Int
        public let cachedInputTokens: Int
        public let outputTokens: Int
        public let totalTokens: Int

        public init(
            costUSD: Double,
            requests: Int,
            inputTokens: Int,
            cachedInputTokens: Int,
            outputTokens: Int,
            totalTokens: Int)
        {
            self.costUSD = costUSD
            self.requests = requests
            self.inputTokens = inputTokens
            self.cachedInputTokens = cachedInputTokens
            self.outputTokens = outputTokens
            self.totalTokens = totalTokens
        }
    }

    public let daily: [DailyBucket]
    public let updatedAt: Date

    public init(daily: [DailyBucket], updatedAt: Date) {
        self.daily = daily.sorted { $0.startTime < $1.startTime }
        self.updatedAt = updatedAt
    }

    public var last30Days: Summary {
        self.summary(days: 30)
    }

    public var last7Days: Summary {
        self.summary(days: 7)
    }

    public var latestDay: Summary {
        self.summary(days: 1)
    }

    public func summary(days: Int) -> Summary {
        let selected = self.daily.suffix(max(1, days))
        return Summary(
            costUSD: selected.reduce(0) { $0 + $1.costUSD },
            requests: selected.reduce(0) { $0 + $1.requests },
            inputTokens: selected.reduce(0) { $0 + $1.inputTokens },
            cachedInputTokens: selected.reduce(0) { $0 + $1.cachedInputTokens },
            outputTokens: selected.reduce(0) { $0 + $1.outputTokens },
            totalTokens: selected.reduce(0) { $0 + $1.totalTokens })
    }

    public var topModels: [ModelBreakdown] {
        var totals: [String: ModelAccumulator] = [:]
        for day in self.daily {
            for model in day.models {
                totals[model.name, default: ModelAccumulator()].add(model)
            }
        }
        return totals
            .map { name, total in total.makeModel(name: name) }
            .sorted {
                if $0.totalTokens == $1.totalTokens { return $0.name < $1.name }
                return $0.totalTokens > $1.totalTokens
            }
    }

    public var topLineItems: [LineItemBreakdown] {
        var totals: [String: Double] = [:]
        for day in self.daily {
            for item in day.lineItems {
                totals[item.name, default: 0] += item.costUSD
            }
        }
        return totals
            .map { LineItemBreakdown(name: $0.key, costUSD: $0.value) }
            .sorted {
                if $0.costUSD == $1.costUSD { return $0.name < $1.name }
                return $0.costUSD > $1.costUSD
            }
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let total = self.last30Days
        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: total.costUSD,
                limit: 0,
                currencyCode: "USD",
                period: "Last 30 days",
                updatedAt: self.updatedAt),
            openAIAPIUsage: self,
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .openai,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Admin API"))
    }

    private struct ModelAccumulator {
        var requests = 0
        var inputTokens = 0
        var cachedInputTokens = 0
        var outputTokens = 0
        var totalTokens = 0

        mutating func add(_ model: ModelBreakdown) {
            self.requests += model.requests
            self.inputTokens += model.inputTokens
            self.cachedInputTokens += model.cachedInputTokens
            self.outputTokens += model.outputTokens
            self.totalTokens += model.totalTokens
        }

        func makeModel(name: String) -> ModelBreakdown {
            ModelBreakdown(
                name: name,
                requests: self.requests,
                inputTokens: self.inputTokens,
                cachedInputTokens: self.cachedInputTokens,
                outputTokens: self.outputTokens,
                totalTokens: self.totalTokens)
        }
    }
}
