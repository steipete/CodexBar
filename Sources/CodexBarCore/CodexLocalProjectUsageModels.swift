import Foundation

public struct CodexLocalProjectUsageIndexProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case scanningLogs
        case indexingProjects
        case saving
    }

    public let phase: Phase
    public let processedFileCount: Int?
    public let totalFileCount: Int?
    public let indexedFileCount: Int
    public let skippedFileCount: Int

    public init(
        phase: Phase,
        processedFileCount: Int? = nil,
        totalFileCount: Int? = nil,
        indexedFileCount: Int = 0,
        skippedFileCount: Int = 0)
    {
        self.phase = phase
        self.processedFileCount = processedFileCount
        self.totalFileCount = totalFileCount
        self.indexedFileCount = indexedFileCount
        self.skippedFileCount = skippedFileCount
    }
}

public struct CodexLocalProjectUsageSnapshot: Sendable, Codable, Equatable {
    public let updatedAt: Date
    public let historyDays: Int
    public let scopeSignature: String
    public let rootsFingerprint: [String: Int64]
    public let indexedFileCount: Int
    public let skippedFileCount: Int
    public let total: CodexLocalUsageTotals
    public let projects: [CodexLocalProjectUsage]
    public let sessions: [CodexLocalSessionUsage]
    public let modelBreakdowns: [CodexLocalUsageModelBreakdown]
    public let daily: [CodexLocalUsageDailyPoint]
    public let sourceStatus: CodexLocalProjectUsageSourceStatus
    public let modelsAnalytics: CodexModelsAnalyticsPayload?

    private enum CodingKeys: String, CodingKey {
        case updatedAt
        case historyDays
        case scopeSignature
        case rootsFingerprint
        case indexedFileCount
        case skippedFileCount
        case total
        case projects
        case sessions
        case modelBreakdowns
        case daily
        case sourceStatus
        case modelsAnalytics
    }

    public init(
        updatedAt: Date,
        historyDays: Int,
        scopeSignature: String,
        rootsFingerprint: [String: Int64],
        indexedFileCount: Int,
        skippedFileCount: Int,
        total: CodexLocalUsageTotals,
        projects: [CodexLocalProjectUsage],
        sessions: [CodexLocalSessionUsage] = [],
        modelBreakdowns: [CodexLocalUsageModelBreakdown] = [],
        daily: [CodexLocalUsageDailyPoint],
        sourceStatus: CodexLocalProjectUsageSourceStatus = .complete,
        modelsAnalytics: CodexModelsAnalyticsPayload? = nil)
    {
        self.updatedAt = updatedAt
        self.historyDays = historyDays
        self.scopeSignature = scopeSignature
        self.rootsFingerprint = rootsFingerprint
        self.indexedFileCount = indexedFileCount
        self.skippedFileCount = skippedFileCount
        self.total = total
        self.projects = projects
        self.sessions = sessions
        self.modelBreakdowns = modelBreakdowns
        self.daily = daily
        self.sourceStatus = sourceStatus
        self.modelsAnalytics = modelsAnalytics
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Self.CodingKeys.self)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.historyDays = try container.decode(Int.self, forKey: .historyDays)
        self.scopeSignature = try container.decode(String.self, forKey: .scopeSignature)
        self.rootsFingerprint = try container.decode([String: Int64].self, forKey: .rootsFingerprint)
        self.indexedFileCount = try container.decode(Int.self, forKey: .indexedFileCount)
        self.skippedFileCount = try container.decode(Int.self, forKey: .skippedFileCount)
        self.total = try container.decode(CodexLocalUsageTotals.self, forKey: .total)
        self.projects = try container.decode([CodexLocalProjectUsage].self, forKey: .projects)
        self.sessions = try container.decodeIfPresent([CodexLocalSessionUsage].self, forKey: .sessions) ?? []
        self.modelBreakdowns = try container.decodeIfPresent(
            [CodexLocalUsageModelBreakdown].self,
            forKey: .modelBreakdowns) ?? []
        self.daily = try container.decode([CodexLocalUsageDailyPoint].self, forKey: .daily)
        self.sourceStatus = try container.decodeIfPresent(
            CodexLocalProjectUsageSourceStatus.self,
            forKey: .sourceStatus) ?? .complete
        self.modelsAnalytics = try container.decodeIfPresent(
            CodexModelsAnalyticsPayload.self,
            forKey: .modelsAnalytics)
    }

    /// An aggregate without per-project detail cannot render the inspector
    /// truthfully. It should trigger a sidecar-backed refresh instead of
    /// publishing empty charts and session lists beside valid totals.
    public var hasInspectorDetail: Bool {
        let projectsAreComplete = self.projects.allSatisfy { project in
            guard (project.totals.totalTokens ?? 0) > 0 else { return true }
            return !project.daily.isEmpty && (project.sessionCount == 0 || !project.topSessions.isEmpty)
        }
        let sessionsAreComplete = self.sessions.allSatisfy { session in
            guard (session.totals.totalTokens ?? 0) > 0 else { return true }
            return !session.daily.isEmpty
        }
        return projectsAreComplete && sessionsAreComplete
    }
}

extension CodexLocalProjectUsageSnapshot {
    func hidingPersonalInformation(_ isEnabled: Bool) -> Self {
        guard isEnabled else { return self }
        return Self(
            updatedAt: self.updatedAt,
            historyDays: self.historyDays,
            scopeSignature: self.scopeSignature,
            rootsFingerprint: [:],
            indexedFileCount: self.indexedFileCount,
            skippedFileCount: self.skippedFileCount,
            total: self.total,
            projects: self.projects.map { $0.hidingPersonalInformation() },
            sessions: self.sessions.map { $0.hidingPersonalInformation() },
            modelBreakdowns: self.modelBreakdowns,
            daily: self.daily,
            sourceStatus: self.sourceStatus,
            modelsAnalytics: self.modelsAnalytics)
    }
}

public enum CodexLocalProjectUsageSourceStatus: String, Sendable, Codable, Equatable {
    case complete
    case catalogMissing
    case catalogLocked
    case catalogCorrupt
    case catalogIncompatible
    case catalogUnreadable

    public var isPartial: Bool {
        self != .complete
    }

    init(catalog: CodexThreadCatalogCompleteness) {
        switch catalog {
        case .complete:
            self = .complete
        case let .unavailable(failure):
            switch failure {
            case .missing: self = .catalogMissing
            case .locked: self = .catalogLocked
            case .corrupt: self = .catalogCorrupt
            case .incompatible: self = .catalogIncompatible
            case .unreadable: self = .catalogUnreadable
            }
        }
    }
}

public enum CodexLocalUsageSeverity: String, Sendable, Codable, Equatable {
    case normal
    case elevated
    case high
}

public enum CodexLocalCostCoverage: String, Sendable, Codable, Equatable {
    case known
    case partial
    case unavailable
}

public struct CodexLocalCostEstimate: Sendable, Codable, Equatable {
    public let knownUSD: Double
    public let unknownTokens: Int

    public init(knownUSD: Double = 0, unknownTokens: Int = 0) {
        self.knownUSD = max(0, knownUSD)
        self.unknownTokens = max(0, unknownTokens)
    }

    public var coverage: CodexLocalCostCoverage {
        if self.unknownTokens == 0 {
            return .known
        }
        return self.knownUSD > 0 ? .partial : .unavailable
    }

    public var knownUSDOrNil: Double? {
        self.knownUSD > 0 || self.unknownTokens == 0 ? self.knownUSD : nil
    }
}

public struct CodexLocalProjectUsage: Sendable, Codable, Identifiable, Equatable {
    public let id: String
    public let displayName: String
    public let path: String?
    public let totals: CodexLocalUsageTotals
    public let costEstimate: CodexLocalCostEstimate
    public let usageSeverity: CodexLocalUsageSeverity?
    public let sessionCount: Int
    public let latestActivity: Date?
    public let topModel: String?
    public let topSessions: [CodexLocalSessionUsage]
    public let modelBreakdowns: [CodexLocalUsageModelBreakdown]
    /// Raw daily totals belonging to this project. The presentation layer
    /// applies cache inclusion and cost visibility without re-indexing.
    public let daily: [CodexLocalUsageDailyPoint]

    public var severity: CodexLocalUsageSeverity {
        self.usageSeverity ?? .normal
    }

    public var estimatedCostUSD: Double? {
        self.costEstimate.knownUSDOrNil
    }

    public var hasUnknownCost: Bool {
        self.costEstimate.unknownTokens > 0
    }

    public init(
        id: String,
        displayName: String,
        path: String?,
        totals: CodexLocalUsageTotals,
        estimatedCostUSD: Double?,
        hasUnknownCost: Bool,
        sessionCount: Int,
        latestActivity: Date?,
        topModel: String?,
        topSessions: [CodexLocalSessionUsage],
        modelBreakdowns: [CodexLocalUsageModelBreakdown],
        daily: [CodexLocalUsageDailyPoint] = [],
        usageSeverity: CodexLocalUsageSeverity = .normal)
    {
        self.id = id
        self.displayName = displayName
        self.path = path
        self.totals = totals
        self.costEstimate = CodexLocalCostEstimate(
            knownUSD: estimatedCostUSD ?? 0,
            unknownTokens: hasUnknownCost ? totals.totalTokens ?? 0 : 0)
        self.usageSeverity = usageSeverity
        self.sessionCount = sessionCount
        self.latestActivity = latestActivity
        self.topModel = topModel
        self.topSessions = topSessions
        self.modelBreakdowns = modelBreakdowns
        self.daily = daily
    }

    public init(
        id: String,
        displayName: String,
        path: String?,
        totals: CodexLocalUsageTotals,
        costEstimate: CodexLocalCostEstimate,
        sessionCount: Int,
        latestActivity: Date?,
        topModel: String?,
        topSessions: [CodexLocalSessionUsage],
        modelBreakdowns: [CodexLocalUsageModelBreakdown],
        daily: [CodexLocalUsageDailyPoint] = [],
        usageSeverity: CodexLocalUsageSeverity? = nil)
    {
        self.id = id
        self.displayName = displayName
        self.path = path
        self.totals = totals
        self.costEstimate = costEstimate
        self.usageSeverity = usageSeverity
        self.sessionCount = sessionCount
        self.latestActivity = latestActivity
        self.topModel = topModel
        self.topSessions = topSessions
        self.modelBreakdowns = modelBreakdowns
        self.daily = daily
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case path
        case totals
        case costEstimate
        case estimatedCostUSD
        case hasUnknownCost
        case sessionCount
        case latestActivity
        case topModel
        case topSessions
        case modelBreakdowns
        case daily
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.path = try container.decodeIfPresent(String.self, forKey: .path)
        self.totals = try container.decode(CodexLocalUsageTotals.self, forKey: .totals)
        self.costEstimate = try container.decodeIfPresent(CodexLocalCostEstimate.self, forKey: .costEstimate)
            ?? CodexLocalCostEstimate(
                knownUSD: container.decodeIfPresent(Double.self, forKey: .estimatedCostUSD) ?? 0,
                unknownTokens: (container.decodeIfPresent(Bool.self, forKey: .hasUnknownCost) ?? false)
                    ? self.totals.totalTokens ?? 0 : 0)
        // Severity is a display projection and intentionally is not persisted.
        self.usageSeverity = nil
        self.sessionCount = try container.decode(Int.self, forKey: .sessionCount)
        self.latestActivity = try container.decodeIfPresent(Date.self, forKey: .latestActivity)
        self.topModel = try container.decodeIfPresent(String.self, forKey: .topModel)
        self.topSessions = try container.decodeIfPresent([CodexLocalSessionUsage].self, forKey: .topSessions) ?? []
        self.modelBreakdowns = try container.decodeIfPresent(
            [CodexLocalUsageModelBreakdown].self,
            forKey: .modelBreakdowns) ?? []
        self.daily = try container.decodeIfPresent([CodexLocalUsageDailyPoint].self, forKey: .daily) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.displayName, forKey: .displayName)
        try container.encodeIfPresent(self.path, forKey: .path)
        try container.encode(self.totals, forKey: .totals)
        try container.encode(self.costEstimate, forKey: .costEstimate)
        try container.encode(self.sessionCount, forKey: .sessionCount)
        try container.encodeIfPresent(self.latestActivity, forKey: .latestActivity)
        try container.encodeIfPresent(self.topModel, forKey: .topModel)
        try container.encode(self.topSessions, forKey: .topSessions)
        try container.encode(self.modelBreakdowns, forKey: .modelBreakdowns)
        try container.encode(self.daily, forKey: .daily)
    }
}

extension CodexLocalProjectUsage {
    fileprivate func hidingPersonalInformation() -> Self {
        Self(
            id: self.id,
            displayName: self.id == CodexLocalProjectRootResolver.chatsProjectId
                ? CodexLocalProjectRootResolver.chatsDisplayName
                : "Workspace",
            path: nil,
            totals: self.totals,
            costEstimate: self.costEstimate,
            sessionCount: self.sessionCount,
            latestActivity: self.latestActivity,
            topModel: self.topModel,
            topSessions: self.topSessions.map { $0.hidingPersonalInformation() },
            modelBreakdowns: self.modelBreakdowns,
            daily: self.daily,
            usageSeverity: self.usageSeverity)
    }
}

public struct CodexLocalSessionUsage: Sendable, Codable, Identifiable, Equatable {
    /// Semantic fallback used when Codex did not persist a title. UI layers
    /// localize this value instead of storing a localization key in Core.
    public static let localChatFallbackTitle = "Local Codex chat"

    public let id: String
    public let projectId: String
    public let displayTitle: String
    public let cwd: String?
    public let startedAt: Date?
    public let latestActivity: Date?
    public let totals: CodexLocalUsageTotals
    public let costEstimate: CodexLocalCostEstimate
    public let topModel: String?
    public let daily: [CodexLocalUsageDailyPoint]

    public init(
        id: String,
        projectId: String,
        displayTitle: String,
        cwd: String?,
        startedAt: Date?,
        latestActivity: Date?,
        totals: CodexLocalUsageTotals,
        estimatedCostUSD: Double?,
        hasUnknownCost: Bool,
        topModel: String?,
        daily: [CodexLocalUsageDailyPoint] = [])
    {
        self.id = id
        self.projectId = projectId
        self.displayTitle = displayTitle
        self.cwd = cwd
        self.startedAt = startedAt
        self.latestActivity = latestActivity
        self.totals = totals
        self.costEstimate = CodexLocalCostEstimate(
            knownUSD: estimatedCostUSD ?? 0,
            unknownTokens: hasUnknownCost ? totals.totalTokens ?? 0 : 0)
        self.topModel = topModel
        self.daily = daily
    }

    public var estimatedCostUSD: Double? {
        self.costEstimate.knownUSDOrNil
    }

    public var hasUnknownCost: Bool {
        self.costEstimate.unknownTokens > 0
    }

    public init(
        id: String,
        projectId: String,
        displayTitle: String,
        cwd: String?,
        startedAt: Date?,
        latestActivity: Date?,
        totals: CodexLocalUsageTotals,
        costEstimate: CodexLocalCostEstimate,
        topModel: String?,
        daily: [CodexLocalUsageDailyPoint] = [])
    {
        self.id = id
        self.projectId = projectId
        self.displayTitle = displayTitle
        self.cwd = cwd
        self.startedAt = startedAt
        self.latestActivity = latestActivity
        self.totals = totals
        self.costEstimate = costEstimate
        self.topModel = topModel
        self.daily = daily
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case projectId
        case displayTitle
        case cwd
        case startedAt
        case latestActivity
        case totals
        case costEstimate
        case estimatedCostUSD
        case hasUnknownCost
        case topModel
        case daily
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.projectId = try container.decode(String.self, forKey: .projectId)
        self.displayTitle = try container.decode(String.self, forKey: .displayTitle)
        self.cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        self.startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        self.latestActivity = try container.decodeIfPresent(Date.self, forKey: .latestActivity)
        self.totals = try container.decode(CodexLocalUsageTotals.self, forKey: .totals)
        self.costEstimate = try container.decodeIfPresent(CodexLocalCostEstimate.self, forKey: .costEstimate)
            ?? CodexLocalCostEstimate(
                knownUSD: container.decodeIfPresent(Double.self, forKey: .estimatedCostUSD) ?? 0,
                unknownTokens: (container.decodeIfPresent(Bool.self, forKey: .hasUnknownCost) ?? false)
                    ? self.totals.totalTokens ?? 0 : 0)
        self.topModel = try container.decodeIfPresent(String.self, forKey: .topModel)
        self.daily = try container.decodeIfPresent([CodexLocalUsageDailyPoint].self, forKey: .daily) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.projectId, forKey: .projectId)
        try container.encode(self.displayTitle, forKey: .displayTitle)
        try container.encodeIfPresent(self.cwd, forKey: .cwd)
        try container.encodeIfPresent(self.startedAt, forKey: .startedAt)
        try container.encodeIfPresent(self.latestActivity, forKey: .latestActivity)
        try container.encode(self.totals, forKey: .totals)
        try container.encode(self.costEstimate, forKey: .costEstimate)
        try container.encodeIfPresent(self.topModel, forKey: .topModel)
        try container.encode(self.daily, forKey: .daily)
    }
}

extension CodexLocalSessionUsage {
    fileprivate func hidingPersonalInformation() -> Self {
        Self(
            id: self.id,
            projectId: self.projectId,
            displayTitle: Self.localChatFallbackTitle,
            cwd: nil,
            startedAt: self.startedAt,
            latestActivity: self.latestActivity,
            totals: self.totals,
            costEstimate: self.costEstimate,
            topModel: self.topModel,
            daily: self.daily)
    }
}

public struct CodexLocalUsageTotals: Sendable, Codable, Equatable {
    public let inputTokens: Int?
    public let cachedInputTokens: Int?
    public let outputTokens: Int?
    public let reasoningOutputTokens: Int?
    public let totalTokens: Int?

    public init(
        inputTokens: Int?,
        cachedInputTokens: Int?,
        outputTokens: Int?,
        reasoningOutputTokens: Int? = nil,
        totalTokens: Int?)
    {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
    }

    public static let unknown = CodexLocalUsageTotals(
        inputTokens: nil,
        cachedInputTokens: nil,
        outputTokens: nil,
        totalTokens: nil)

    public static let empty = CodexLocalUsageTotals(
        inputTokens: 0,
        cachedInputTokens: 0,
        outputTokens: 0,
        totalTokens: 0)

    public func adding(_ other: CodexLocalUsageTotals) -> CodexLocalUsageTotals {
        CodexLocalUsageTotals(
            inputTokens: Self.add(self.inputTokens, other.inputTokens),
            cachedInputTokens: Self.add(self.cachedInputTokens, other.cachedInputTokens),
            outputTokens: Self.add(self.outputTokens, other.outputTokens),
            reasoningOutputTokens: Self.add(self.reasoningOutputTokens, other.reasoningOutputTokens),
            totalTokens: Self.add(self.totalTokens, other.totalTokens))
    }

    private static func add(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            lhs + rhs
        case let (lhs?, nil):
            lhs
        case let (nil, rhs?):
            rhs
        case (nil, nil):
            nil
        }
    }
}

public struct CodexLocalUsageModelBreakdown: Sendable, Codable, Identifiable, Equatable {
    public var id: String {
        self.model
    }

    public let model: String
    public let totals: CodexLocalUsageTotals
    public let costEstimate: CodexLocalCostEstimate

    public init(
        model: String,
        totals: CodexLocalUsageTotals,
        estimatedCostUSD: Double?,
        hasUnknownCost: Bool)
    {
        self.model = model
        self.totals = totals
        self.costEstimate = CodexLocalCostEstimate(
            knownUSD: estimatedCostUSD ?? 0,
            unknownTokens: hasUnknownCost ? totals.totalTokens ?? 0 : 0)
    }

    public var estimatedCostUSD: Double? {
        self.costEstimate.knownUSDOrNil
    }

    public var hasUnknownCost: Bool {
        self.costEstimate.unknownTokens > 0
    }

    public init(model: String, totals: CodexLocalUsageTotals, costEstimate: CodexLocalCostEstimate) {
        self.model = model
        self.totals = totals
        self.costEstimate = costEstimate
    }

    private enum CodingKeys: String, CodingKey {
        case model
        case totals
        case costEstimate
        case estimatedCostUSD
        case hasUnknownCost
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.model = try container.decode(String.self, forKey: .model)
        self.totals = try container.decode(CodexLocalUsageTotals.self, forKey: .totals)
        self.costEstimate = try container.decodeIfPresent(CodexLocalCostEstimate.self, forKey: .costEstimate)
            ?? CodexLocalCostEstimate(
                knownUSD: container.decodeIfPresent(Double.self, forKey: .estimatedCostUSD) ?? 0,
                unknownTokens: (container.decodeIfPresent(Bool.self, forKey: .hasUnknownCost) ?? false)
                    ? self.totals.totalTokens ?? 0 : 0)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.model, forKey: .model)
        try container.encode(self.totals, forKey: .totals)
        try container.encode(self.costEstimate, forKey: .costEstimate)
    }
}

public struct CodexLocalUsageDailyPoint: Sendable, Codable, Identifiable, Equatable {
    public var id: String {
        self.day
    }

    public let day: String
    public let totalTokens: Int
    public let cachedInputTokens: Int?
    public let estimatedCostUSD: Double?

    public init(
        day: String,
        totalTokens: Int,
        cachedInputTokens: Int? = nil,
        estimatedCostUSD: Double?)
    {
        self.day = day
        self.totalTokens = totalTokens
        self.cachedInputTokens = cachedInputTokens
        self.estimatedCostUSD = estimatedCostUSD
    }

    private enum CodingKeys: String, CodingKey {
        case day
        case totalTokens
        case cachedInputTokens
        case estimatedCostUSD
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.day = try container.decode(String.self, forKey: .day)
        self.totalTokens = try container.decode(Int.self, forKey: .totalTokens)
        self.cachedInputTokens = try container.decodeIfPresent(Int.self, forKey: .cachedInputTokens)
        self.estimatedCostUSD = try container.decodeIfPresent(Double.self, forKey: .estimatedCostUSD)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.day, forKey: .day)
        try container.encode(self.totalTokens, forKey: .totalTokens)
        try container.encodeIfPresent(self.cachedInputTokens, forKey: .cachedInputTokens)
        try container.encodeIfPresent(self.estimatedCostUSD, forKey: .estimatedCostUSD)
    }
}
