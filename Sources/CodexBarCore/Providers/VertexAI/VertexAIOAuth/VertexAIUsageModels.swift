import Foundation

public enum VertexAIQuotaCadence: String, Sendable, Equatable {
    case perMinute
    case perDay
    case allocation
}

public struct VertexAIQuotaBucketUsage: Sendable, Equatable {
    public let quotaMetric: String
    public let limitName: String
    public let displayName: String?
    public let location: String
    public let baseModel: String?
    public let cadence: VertexAIQuotaCadence
    public let usage: Double
    public let limit: Double
    public let usedPercent: Double
    public let exceededCount: Int
    public let unit: String?
    public let resetsAt: Date?

    public init(
        quotaMetric: String,
        limitName: String,
        displayName: String? = nil,
        location: String,
        baseModel: String? = nil,
        cadence: VertexAIQuotaCadence,
        usage: Double,
        limit: Double,
        usedPercent: Double,
        exceededCount: Int = 0,
        unit: String? = nil,
        resetsAt: Date? = nil)
    {
        self.quotaMetric = quotaMetric
        self.limitName = limitName
        self.displayName = displayName
        self.location = location
        self.baseModel = baseModel
        self.cadence = cadence
        self.usage = usage
        self.limit = limit
        self.usedPercent = usedPercent
        self.exceededCount = exceededCount
        self.unit = unit
        self.resetsAt = resetsAt
    }

    public var isTokenQuota: Bool {
        let metric = self.quotaMetric.lowercased()
        let unit = self.unit?.lowercased() ?? ""
        return metric.contains("token") || unit.contains("token")
    }
}

public struct VertexAIOnlineServingModelSummary: Sendable, Equatable {
    public let modelUserID: String
    public let location: String
    public let publisher: String
    public let requestType: String
    public let invocations: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let estimatedCostUSD: Double?
    public let tokensAreComplete: Bool

    public var totalTokens: Int {
        self.inputTokens + self.outputTokens
    }

    public init(
        modelUserID: String,
        location: String,
        publisher: String,
        requestType: String,
        invocations: Int,
        inputTokens: Int,
        outputTokens: Int,
        estimatedCostUSD: Double? = nil,
        tokensAreComplete: Bool = true)
    {
        self.modelUserID = modelUserID
        self.location = location
        self.publisher = publisher
        self.requestType = requestType
        self.invocations = invocations
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.tokensAreComplete = tokensAreComplete
    }
}

public struct VertexAIOnlineServingSummary: Sendable, Equatable {
    public let totalInvocations: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let sharedInvocations: Int
    public let dedicatedInvocations: Int
    public let sharedTokens: Int
    public let dedicatedTokens: Int
    public let estimatedCostUSD: Double?
    public let hasUnpricedTokens: Bool
    public let tokensAreComplete: Bool
    public let models: [VertexAIOnlineServingModelSummary]

    public var totalTokens: Int {
        self.inputTokens + self.outputTokens
    }

    public init(
        totalInvocations: Int,
        inputTokens: Int,
        outputTokens: Int,
        sharedInvocations: Int,
        dedicatedInvocations: Int,
        sharedTokens: Int,
        dedicatedTokens: Int,
        estimatedCostUSD: Double? = nil,
        hasUnpricedTokens: Bool = false,
        tokensAreComplete: Bool = true,
        models: [VertexAIOnlineServingModelSummary])
    {
        self.totalInvocations = totalInvocations
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.sharedInvocations = sharedInvocations
        self.dedicatedInvocations = dedicatedInvocations
        self.sharedTokens = sharedTokens
        self.dedicatedTokens = dedicatedTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.hasUnpricedTokens = hasUnpricedTokens
        self.tokensAreComplete = tokensAreComplete
        self.models = models
    }
}

public struct VertexAIQueryOptions: Sendable, Equatable {
    public let locationFilter: String?
    public let baseModelFilter: String?
    public let includeOnlineServing: Bool
    public let servingWindowDays: Int
    public let estimateServingCost: Bool

    public init(
        locationFilter: String? = nil,
        baseModelFilter: String? = nil,
        includeOnlineServing: Bool = true,
        servingWindowDays: Int = 1,
        estimateServingCost: Bool = true)
    {
        let trimmedLocation = locationFilter?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.locationFilter = (trimmedLocation?.isEmpty == false) ? trimmedLocation : nil
        let trimmedModel = baseModelFilter?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseModelFilter = (trimmedModel?.isEmpty == false) ? trimmedModel : nil
        self.includeOnlineServing = includeOnlineServing
        self.servingWindowDays = max(1, servingWindowDays)
        self.estimateServingCost = estimateServingCost
    }
}

public struct VertexAIUsageResponse: Sendable {
    public let requestsUsedPercent: Double
    public let tokensUsedPercent: Double?
    public let resetsAt: Date?
    public let resetDescription: String?
    public let rawData: String?
    public let rateQuotas: [VertexAIQuotaBucketUsage]
    public let allocationQuotas: [VertexAIQuotaBucketUsage]
    public let highestRateQuota: VertexAIQuotaBucketUsage?
    public let highestAllocationQuota: VertexAIQuotaBucketUsage?
    public let totalExceededCount: Int
    public let onlineServingSummary: VertexAIOnlineServingSummary?

    public init(
        requestsUsedPercent: Double,
        tokensUsedPercent: Double?,
        resetsAt: Date?,
        resetDescription: String?,
        rawData: String?,
        rateQuotas: [VertexAIQuotaBucketUsage] = [],
        allocationQuotas: [VertexAIQuotaBucketUsage] = [],
        highestRateQuota: VertexAIQuotaBucketUsage? = nil,
        highestAllocationQuota: VertexAIQuotaBucketUsage? = nil,
        totalExceededCount: Int = 0,
        onlineServingSummary: VertexAIOnlineServingSummary? = nil)
    {
        self.requestsUsedPercent = requestsUsedPercent
        self.tokensUsedPercent = tokensUsedPercent
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
        self.rawData = rawData
        self.rateQuotas = rateQuotas
        self.allocationQuotas = allocationQuotas
        self.highestRateQuota = highestRateQuota
        self.highestAllocationQuota = highestAllocationQuota
        self.totalExceededCount = totalExceededCount
        self.onlineServingSummary = onlineServingSummary
    }
}
