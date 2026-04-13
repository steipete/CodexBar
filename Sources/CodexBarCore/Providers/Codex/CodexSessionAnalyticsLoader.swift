import Foundation

public struct CodexSessionTokenUsage: Sendable, Equatable, Codable {
    public let totalTokens: Int
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let outputTokens: Int
    public let reasoningOutputTokens: Int

    public init(
        totalTokens: Int,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        reasoningOutputTokens: Int)
    {
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
    }
}

public struct CodexSessionAnalyticsSummaryDiagnostics: Sendable, Equatable {
    public let windowSpanSeconds: TimeInterval
    public let sessionsWithTokens: Int
    public let sessionsWithFailures: Int
    public let sessionsWithChecks: Int
    public let durationP25Seconds: TimeInterval
    public let durationP50Seconds: TimeInterval
    public let durationP75Seconds: TimeInterval
    public let longestSessionDurationSeconds: TimeInterval
    public let top3DurationShare: Double
    public let avgToolCalls: Double
    public let toolCallsP75: Double
    public let sessionsOver50Calls: Int
    public let sessionsOver100Calls: Int
    public let maxToolCallsInSingleSession: Int
    public let failedCalls: Int
    public let totalCalls: Int
    public let topFailingToolName: String?
    public let topFailingToolFailures: Int

    public static let empty = CodexSessionAnalyticsSummaryDiagnostics(
        windowSpanSeconds: 0,
        sessionsWithTokens: 0,
        sessionsWithFailures: 0,
        sessionsWithChecks: 0,
        durationP25Seconds: 0,
        durationP50Seconds: 0,
        durationP75Seconds: 0,
        longestSessionDurationSeconds: 0,
        top3DurationShare: 0,
        avgToolCalls: 0,
        toolCallsP75: 0,
        sessionsOver50Calls: 0,
        sessionsOver100Calls: 0,
        maxToolCallsInSingleSession: 0,
        failedCalls: 0,
        totalCalls: 0,
        topFailingToolName: nil,
        topFailingToolFailures: 0)

    public init(
        windowSpanSeconds: TimeInterval,
        sessionsWithTokens: Int,
        sessionsWithFailures: Int,
        sessionsWithChecks: Int,
        durationP25Seconds: TimeInterval,
        durationP50Seconds: TimeInterval,
        durationP75Seconds: TimeInterval,
        longestSessionDurationSeconds: TimeInterval,
        top3DurationShare: Double,
        avgToolCalls: Double,
        toolCallsP75: Double,
        sessionsOver50Calls: Int,
        sessionsOver100Calls: Int,
        maxToolCallsInSingleSession: Int,
        failedCalls: Int,
        totalCalls: Int,
        topFailingToolName: String?,
        topFailingToolFailures: Int)
    {
        self.windowSpanSeconds = windowSpanSeconds
        self.sessionsWithTokens = sessionsWithTokens
        self.sessionsWithFailures = sessionsWithFailures
        self.sessionsWithChecks = sessionsWithChecks
        self.durationP25Seconds = durationP25Seconds
        self.durationP50Seconds = durationP50Seconds
        self.durationP75Seconds = durationP75Seconds
        self.longestSessionDurationSeconds = longestSessionDurationSeconds
        self.top3DurationShare = top3DurationShare
        self.avgToolCalls = avgToolCalls
        self.toolCallsP75 = toolCallsP75
        self.sessionsOver50Calls = sessionsOver50Calls
        self.sessionsOver100Calls = sessionsOver100Calls
        self.maxToolCallsInSingleSession = maxToolCallsInSingleSession
        self.failedCalls = failedCalls
        self.totalCalls = totalCalls
        self.topFailingToolName = topFailingToolName
        self.topFailingToolFailures = topFailingToolFailures
    }
}

public struct CodexSessionSummary: Sendable, Equatable, Codable {
    public let id: String
    public let title: String
    public let startedAt: Date
    public let durationSeconds: TimeInterval
    public let toolCallCount: Int
    public let toolFailureCount: Int
    public let longRunningCallCount: Int
    public let verificationAttemptCount: Int
    public let toolCountsByName: [String: Int]
    public let toolFailureCountsByName: [String: Int]
    public let toolLongRunningCountsByName: [String: Int]
    public let tokenUsage: CodexSessionTokenUsage?

    public init(
        id: String,
        title: String,
        startedAt: Date,
        durationSeconds: TimeInterval,
        toolCallCount: Int,
        toolFailureCount: Int,
        longRunningCallCount: Int,
        verificationAttemptCount: Int,
        toolCountsByName: [String: Int],
        toolFailureCountsByName: [String: Int] = [:],
        toolLongRunningCountsByName: [String: Int] = [:],
        tokenUsage: CodexSessionTokenUsage? = nil)
    {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.toolCallCount = toolCallCount
        self.toolFailureCount = toolFailureCount
        self.longRunningCallCount = longRunningCallCount
        self.verificationAttemptCount = verificationAttemptCount
        self.toolCountsByName = toolCountsByName
        self.toolFailureCountsByName = toolFailureCountsByName
        self.toolLongRunningCountsByName = toolLongRunningCountsByName
        self.tokenUsage = tokenUsage
    }
}

public struct CodexToolAggregate: Sendable, Equatable {
    public let name: String
    public let callCount: Int
    public let sessionCountUsingTool: Int
    public let callShare: Double
    public let averageCallsPerActiveSession: Double
    public let maxCallsInSingleSession: Int
    public let maxCallsSessionTitle: String?
    public let failureCount: Int
    public let failureRate: Double
    public let sessionsWithToolFailure: Int
    public let longRunningCount: Int

    public init(
        name: String,
        callCount: Int,
        sessionCountUsingTool: Int = 0,
        callShare: Double = 0,
        averageCallsPerActiveSession: Double = 0,
        maxCallsInSingleSession: Int = 0,
        maxCallsSessionTitle: String? = nil,
        failureCount: Int = 0,
        failureRate: Double = 0,
        sessionsWithToolFailure: Int = 0,
        longRunningCount: Int = 0)
    {
        self.name = name
        self.callCount = callCount
        self.sessionCountUsingTool = sessionCountUsingTool
        self.callShare = callShare
        self.averageCallsPerActiveSession = averageCallsPerActiveSession
        self.maxCallsInSingleSession = maxCallsInSingleSession
        self.maxCallsSessionTitle = maxCallsSessionTitle
        self.failureCount = failureCount
        self.failureRate = failureRate
        self.sessionsWithToolFailure = sessionsWithToolFailure
        self.longRunningCount = longRunningCount
    }
}

public struct CodexSessionAnalyticsSnapshot: Sendable, Equatable {
    public let generatedAt: Date
    public let sessions: [CodexSessionSummary]
    public let medianSessionDurationSeconds: TimeInterval
    public let medianToolCallsPerSession: Double
    public let toolFailureRate: Double
    public let topTools: [CodexToolAggregate]
    public let summaryDiagnostics: CodexSessionAnalyticsSummaryDiagnostics

    public init(
        generatedAt: Date,
        sessions: [CodexSessionSummary],
        medianSessionDurationSeconds: TimeInterval,
        medianToolCallsPerSession: Double,
        toolFailureRate: Double,
        topTools: [CodexToolAggregate],
        summaryDiagnostics: CodexSessionAnalyticsSummaryDiagnostics = .empty)
    {
        self.generatedAt = generatedAt
        self.sessions = sessions
        self.medianSessionDurationSeconds = medianSessionDurationSeconds
        self.medianToolCallsPerSession = medianToolCallsPerSession
        self.toolFailureRate = toolFailureRate
        self.topTools = topTools
        self.summaryDiagnostics = summaryDiagnostics
    }

    public var sessionsAnalyzed: Int {
        self.sessions.count
    }

    public var recentSessions: [CodexSessionSummary] {
        Array(self.sessions.prefix(8))
    }
}

public struct CodexSessionAnalyticsLoader {
    private let indexer: CodexSessionAnalyticsIndexer

    public init(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        homeDirectoryURL: URL? = nil)
    {
        self.indexer = CodexSessionAnalyticsIndexer(
            env: env,
            fileManager: fileManager,
            homeDirectoryURL: homeDirectoryURL)
    }

    public func loadSnapshot(maxSessions: Int = 20, now: Date = .now) throws -> CodexSessionAnalyticsSnapshot? {
        let index = try self.indexer.refreshIndex(existing: nil, now: now, persist: false)
        return CodexSessionAnalyticsSnapshotBuilder.buildSnapshot(
            from: index,
            maxSessions: maxSessions,
            now: now)
    }
}
