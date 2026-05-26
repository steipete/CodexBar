import Foundation

// MARK: - API Response Models

/// Top-level response from `GET https://admin.mistral.ai/api/billing/v2/usage`.
struct MistralBillingResponse: Codable {
    let completion: MistralModelUsageCategory?
    let ocr: MistralModelUsageCategory?
    let connectors: MistralModelUsageCategory?
    let librariesApi: MistralLibrariesUsageCategory?
    let fineTuning: MistralFineTuningCategory?
    let audio: MistralModelUsageCategory?
    let vibeUsage: Double?
    let date: String?
    let previousMonth: String?
    let nextMonth: String?
    let startDate: String?
    let endDate: String?
    let currency: String?
    let currencySymbol: String?
    let prices: [MistralPrice]?

    enum CodingKeys: String, CodingKey {
        case completion, ocr, connectors, audio, date, currency, prices
        case librariesApi = "libraries_api"
        case fineTuning = "fine_tuning"
        case vibeUsage = "vibe_usage"
        case previousMonth = "previous_month"
        case nextMonth = "next_month"
        case startDate = "start_date"
        case endDate = "end_date"
        case currencySymbol = "currency_symbol"
    }
}

struct MistralModelUsageCategory: Codable {
    let models: [String: MistralModelUsageData]?
}

struct MistralLibrariesUsageCategory: Codable {
    let pages: MistralModelUsageCategory?
    let tokens: MistralModelUsageCategory?
}

struct MistralFineTuningCategory: Codable {
    let training: [String: MistralModelUsageData]?
    let storage: [String: MistralModelUsageData]?
}

struct MistralModelUsageData: Codable {
    let input: [MistralUsageEntry]?
    let output: [MistralUsageEntry]?
    let cached: [MistralUsageEntry]?
}

struct MistralUsageEntry: Codable {
    let usageType: String?
    let eventType: String?
    let billingMetric: String?
    let billingDisplayName: String?
    let billingGroup: String?
    let timestamp: String?
    let value: Int?
    let valuePaid: Int?

    enum CodingKeys: String, CodingKey {
        case timestamp, value
        case usageType = "usage_type"
        case eventType = "event_type"
        case billingMetric = "billing_metric"
        case billingDisplayName = "billing_display_name"
        case billingGroup = "billing_group"
        case valuePaid = "value_paid"
    }
}

struct MistralPrice: Codable {
    let eventType: String?
    let billingMetric: String?
    let billingGroup: String?
    let price: String?

    enum CodingKeys: String, CodingKey {
        case price
        case eventType = "event_type"
        case billingMetric = "billing_metric"
        case billingGroup = "billing_group"
    }
}

// MARK: - Intermediate Snapshot

public struct MistralDailyUsageBucket: Codable, Equatable, Sendable, Identifiable {
    public struct ModelBreakdown: Codable, Equatable, Sendable, Identifiable {
        public let name: String
        public let cost: Double
        public let inputTokens: Int
        public let cachedTokens: Int
        public let outputTokens: Int

        public var id: String {
            self.name
        }

        public var totalTokens: Int {
            self.inputTokens + self.cachedTokens + self.outputTokens
        }

        public init(name: String, cost: Double, inputTokens: Int, cachedTokens: Int, outputTokens: Int) {
            self.name = name
            self.cost = cost
            self.inputTokens = inputTokens
            self.cachedTokens = cachedTokens
            self.outputTokens = outputTokens
        }
    }

    public let day: String
    public let cost: Double
    public let inputTokens: Int
    public let cachedTokens: Int
    public let outputTokens: Int
    public let models: [ModelBreakdown]

    public var id: String {
        self.day
    }

    public var totalTokens: Int {
        self.inputTokens + self.cachedTokens + self.outputTokens
    }

    public init(
        day: String,
        cost: Double,
        inputTokens: Int,
        cachedTokens: Int,
        outputTokens: Int,
        models: [ModelBreakdown])
    {
        self.day = day
        self.cost = cost
        self.inputTokens = inputTokens
        self.cachedTokens = cachedTokens
        self.outputTokens = outputTokens
        self.models = models
    }
}

public struct MistralUsageSnapshot: Codable, Sendable {
    public let totalCost: Double
    public let currency: String
    public let currencySymbol: String
    public let totalInputTokens: Int
    public let totalOutputTokens: Int
    public let totalCachedTokens: Int
    public let modelCount: Int
    public let daily: [MistralDailyUsageBucket]
    public let startDate: Date?
    public let endDate: Date?
    public let updatedAt: Date

    public init(
        totalCost: Double,
        currency: String,
        currencySymbol: String,
        totalInputTokens: Int,
        totalOutputTokens: Int,
        totalCachedTokens: Int,
        modelCount: Int,
        daily: [MistralDailyUsageBucket] = [],
        startDate: Date?,
        endDate: Date?,
        updatedAt: Date)
    {
        self.totalCost = totalCost
        self.currency = currency
        self.currencySymbol = currencySymbol
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.totalCachedTokens = totalCachedTokens
        self.modelCount = modelCount
        self.daily = daily.sorted { $0.day < $1.day }
        self.startDate = startDate
        self.endDate = endDate
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        // Negative totalCost means a refund/credit adjustment; clamp to zero rather than
        // showing a confusing negative amount in the menu bar.
        let spendText = if self.totalCost > 0 {
            "\(self.currencySymbol)\(String(format: "%.4f", self.totalCost)) this month"
        } else {
            "\(self.currencySymbol)0.0000 this month"
        }
        let identity = ProviderIdentitySnapshot(
            providerID: .mistral,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "API spend: \(spendText)")
        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: nil,
            mistralUsage: self,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    public func toCostUsageTokenSnapshot(historyDays: Int = 30) -> CostUsageTokenSnapshot {
        let clampedHistoryDays = max(1, min(365, historyDays))
        let selected = self.daily
        let entries = selected.map { bucket in
            let modelBreakdowns = bucket.models.map {
                CostUsageDailyReport.ModelBreakdown(
                    modelName: $0.name,
                    costUSD: max($0.cost, 0),
                    totalTokens: $0.totalTokens)
            }
            let modelsUsed = bucket.models.map(\.name)
            return CostUsageDailyReport.Entry(
                date: bucket.day,
                inputTokens: bucket.inputTokens,
                outputTokens: bucket.outputTokens,
                cacheReadTokens: bucket.cachedTokens,
                cacheCreationTokens: nil,
                totalTokens: bucket.totalTokens,
                costUSD: max(bucket.cost, 0),
                modelsUsed: modelsUsed.isEmpty ? nil : modelsUsed,
                modelBreakdowns: modelBreakdowns.isEmpty ? nil : modelBreakdowns)
        }
        let latest = selected.last
        let totalCost = max(self.totalCost, 0)
        let totalTokens = selected.isEmpty
            ? self.totalInputTokens + self.totalCachedTokens + self.totalOutputTokens
            : selected.reduce(0) { $0 + $1.totalTokens }
        let cost = totalCost > 0 ? totalCost : nil
        let tokens = totalTokens > 0 ? totalTokens : nil
        return CostUsageTokenSnapshot(
            sessionTokens: latest?.totalTokens,
            sessionCostUSD: latest.map { max($0.cost, 0) },
            last30DaysTokens: tokens,
            last30DaysCostUSD: cost,
            currencyCode: self.currency,
            historyDays: selected.isEmpty ? clampedHistoryDays : max(1, min(365, selected.count)),
            historyLabel: "This month",
            daily: entries,
            updatedAt: self.updatedAt)
    }
}
