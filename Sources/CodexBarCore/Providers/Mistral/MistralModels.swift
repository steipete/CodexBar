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

public struct MistralUsageSnapshot: Sendable {
    public let totalCost: Double
    public let currency: String
    public let currencySymbol: String
    public let totalInputTokens: Int
    public let totalOutputTokens: Int
    public let totalCachedTokens: Int
    public let modelCount: Int
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
            updatedAt: self.updatedAt,
            identity: identity)
    }
}
