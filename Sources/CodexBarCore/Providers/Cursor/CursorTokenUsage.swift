import Foundation

public enum CursorUsageRangeKind: String, Codable, CaseIterable, Sendable {
    case last30Days
    case billingCycle

    public var label: String {
        switch self {
        case .last30Days: "30d"
        case .billingCycle: "Cycle"
        }
    }
}

public struct CursorRangeUsageSummary: Codable, Sendable {
    public let rangeKind: CursorUsageRangeKind
    public let range: CursorRecentRequestRange
    public let tokens: Int
    public let requests: Int
    public let weightedRequestCost: Double
    public let requestCostSummary: CursorRequestCostSummary?
    public let recentRequests: [CursorRecentRequest]

    public init(
        rangeKind: CursorUsageRangeKind,
        range: CursorRecentRequestRange,
        tokens: Int,
        requests: Int,
        weightedRequestCost: Double? = nil,
        requestCostSummary: CursorRequestCostSummary?,
        recentRequests: [CursorRecentRequest])
    {
        self.rangeKind = rangeKind
        self.range = range
        self.tokens = tokens
        self.requests = requests
        self.weightedRequestCost = weightedRequestCost ?? Double(requests)
        self.requestCostSummary = requestCostSummary
        self.recentRequests = recentRequests
    }

    private enum CodingKeys: String, CodingKey {
        case rangeKind
        case range
        case tokens
        case requests
        case weightedRequestCost
        case requestCostSummary
        case recentRequests
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.rangeKind = try container.decode(CursorUsageRangeKind.self, forKey: .rangeKind)
        self.range = try container.decode(CursorRecentRequestRange.self, forKey: .range)
        self.tokens = try container.decode(Int.self, forKey: .tokens)
        self.requests = try container.decode(Int.self, forKey: .requests)
        self.weightedRequestCost = try container.decodeIfPresent(Double.self, forKey: .weightedRequestCost)
            ?? Double(self.requests)
        self.requestCostSummary = try container.decodeIfPresent(
            CursorRequestCostSummary.self,
            forKey: .requestCostSummary)
        self.recentRequests = try container.decode([CursorRecentRequest].self, forKey: .recentRequests)
    }
}

public struct CursorTokenUsage: Codable, Sendable {
    public let billingCycleTokensUsed: Int
    public let requestCostSummary: CursorRequestCostSummary?

    public init(billingCycleTokensUsed: Int, requestCostSummary: CursorRequestCostSummary? = nil) {
        self.billingCycleTokensUsed = billingCycleTokensUsed
        self.requestCostSummary = requestCostSummary
    }
}
