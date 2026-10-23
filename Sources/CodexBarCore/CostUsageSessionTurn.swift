import Foundation

/// One retained, de-duplicated model request. Counts follow the provider's inclusive input/output buckets.
public struct CostUsageSessionRequest: Sendable, Equatable, Identifiable {
    public let id: String
    public let modelName: String
    public let timestamp: Date?
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let outputTokens: Int
    public let reasoningTokens: Int?
    public let totalTokens: Int?
    public let costUSD: Double?

    public init(
        id: String,
        modelName: String,
        timestamp: Date?,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        reasoningTokens: Int?,
        totalTokens: Int?,
        costUSD: Double?)
    {
        self.id = id
        self.modelName = modelName
        self.timestamp = timestamp
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.totalTokens = totalTokens
        self.costUSD = costUSD
    }
}

/// Request-ledger usage grouped by turn inside the selected reporting window.
/// A nil turn ID represents usage that cannot be attributed to an individual turn.
public struct CostUsageSessionTurn: Sendable, Equatable, Identifiable {
    public let turnID: String?
    public let firstActivity: Date?
    public let lastActivity: Date?
    public let inputTokens: Int?
    public let cachedInputTokens: Int?
    public let outputTokens: Int?
    public let reasoningTokens: Int?
    public let totalTokens: Int?
    public let requestCount: Int?
    public let costUSD: Double?
    public let requests: [CostUsageSessionRequest]

    public var id: String {
        self.turnID.map { "turn:\($0)" } ?? "unattributed"
    }

    public init(
        turnID: String?,
        firstActivity: Date?,
        lastActivity: Date?,
        inputTokens: Int?,
        cachedInputTokens: Int?,
        outputTokens: Int?,
        reasoningTokens: Int?,
        totalTokens: Int?,
        requestCount: Int?,
        costUSD: Double?,
        requests: [CostUsageSessionRequest] = [])
    {
        self.turnID = turnID
        self.firstActivity = firstActivity
        self.lastActivity = lastActivity
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.totalTokens = totalTokens
        self.requestCount = requestCount
        self.costUSD = costUSD
        self.requests = requests
    }
}
