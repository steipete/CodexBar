import Foundation

public struct CursorRecentRequestTokenBreakdown: Codable, Equatable, Sendable {
    public enum Confidence: String, Codable, Equatable, Sendable {
        case exactBreakdown
        case partialBreakdown
        case totalOnly
        case empty
    }

    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cacheReadTokens: Int?
    public let cacheWriteTokens: Int?
    public let totalTokens: Int
    public let confidence: Confidence

    public init(
        inputTokens: Int?,
        outputTokens: Int?,
        cacheReadTokens: Int?,
        cacheWriteTokens: Int?,
        totalTokens: Int,
        confidence: Confidence)
    {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.totalTokens = totalTokens
        self.confidence = confidence
    }
}

public struct CursorRecentRequest: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let model: String
    public let tokens: Int
    public let requests: Int
    public let requestCost: Double?
    public let tokenBreakdown: CursorRecentRequestTokenBreakdown?

    public init(
        timestamp: Date,
        model: String,
        tokens: Int,
        requests: Int,
        requestCost: Double? = nil,
        tokenBreakdown: CursorRecentRequestTokenBreakdown? = nil)
    {
        self.timestamp = timestamp
        self.model = model
        self.tokens = tokens
        self.requests = requests
        self.requestCost = requestCost
        self.tokenBreakdown = tokenBreakdown
    }
}

public struct CursorRecentRequestRange: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}
