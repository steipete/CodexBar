import Foundation

/// An estimated local Codex conversation total derived from one session log.
/// This is intentionally distinct from account-level billing or quota data.
public struct CostUsageSessionBreakdown: Sendable, Equatable, Identifiable {
    public let sessionID: String
    public let lastActivity: Date
    public let inputTokens: Int?
    public let cachedInputTokens: Int?
    public let outputTokens: Int?
    public let reasoningTokens: Int?
    public let totalTokens: Int?
    public let requestCount: Int?
    public let costUSD: Double?
    public let modelBreakdowns: [CostUsageDailyReport.ModelBreakdown]
    /// Canonical project path, matching the key of the session's Projects row.
    public let projectPath: String?
    public internal(set) var projectName: String?
    /// Thread name from Codex metadata, when one exists.
    public private(set) var title: String?
    public let turnPerformanceSamples: [CostUsageTurnPerformanceSample]
    public let toolActivitySource: SessionToolActivitySource?
    /// Original rollout directory; relative SQLite homes must not use the canonical project path.
    var workingDirectory: String?

    public var id: String {
        self.sessionID
    }

    public init(
        sessionID: String,
        lastActivity: Date,
        inputTokens: Int?,
        cachedInputTokens: Int?,
        outputTokens: Int?,
        reasoningTokens: Int? = nil,
        totalTokens: Int?,
        requestCount: Int?,
        costUSD: Double?,
        modelBreakdowns: [CostUsageDailyReport.ModelBreakdown],
        projectPath: String? = nil,
        projectName: String? = nil,
        title: String? = nil,
        turnPerformanceSamples: [CostUsageTurnPerformanceSample] = [],
        toolActivitySource: SessionToolActivitySource? = nil)
    {
        self.sessionID = sessionID
        self.lastActivity = lastActivity
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.totalTokens = totalTokens
        self.requestCount = requestCount
        self.costUSD = costUSD
        self.modelBreakdowns = modelBreakdowns
        self.projectPath = projectPath
        self.projectName = projectName
        self.title = title
        self.turnPerformanceSamples = turnPerformanceSamples
        self.toolActivitySource = toolActivitySource
    }

    public func withTitle(_ title: String?) -> CostUsageSessionBreakdown {
        var copy = self
        copy.title = title
        return copy
    }
}
