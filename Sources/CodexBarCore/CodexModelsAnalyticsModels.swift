import Foundation

public enum CodexModelsRollout {
    public static let featureFlagKey = "codex.models.revamp.enabled"
    public static let defaultEnabled = true

    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: self.featureFlagKey) as? Bool ?? self.defaultEnabled
    }
}

public enum CodexModelsMetric: String, CaseIterable, Codable, Identifiable, Sendable {
    case tokens
    case knownCost
    case sessionReferences

    public var id: Self {
        self
    }

    public var title: String {
        switch self {
        case .tokens: "Tokens"
        case .knownCost: "Cost"
        case .sessionReferences: "Session refs"
        }
    }
}

public enum CodexModelsGranularity: String, CaseIterable, Codable, Identifiable, Sendable {
    case daily
    case weekly
    case monthly

    public var id: Self {
        self
    }

    public var title: String {
        self.rawValue.capitalized
    }
}

public enum CodexModelsComparison: Codable, Equatable, Sendable {
    case unavailable
    case new
    case ended
    case unchanged
    case percent(Double)

    public static func make(current: Double, previous: Double, previousIsComplete: Bool = true) -> Self {
        guard previousIsComplete else { return .unavailable }
        if current == 0, previous == 0 { return .unchanged }
        if previous == 0 { return .new }
        if current == 0 { return .ended }
        let value = (current - previous) / previous
        return value == 0 ? .unchanged : .percent(value)
    }

    public var sortableValue: Double {
        switch self {
        case .unavailable: -.infinity
        case .new: .infinity
        case .ended: -1
        case .unchanged: 0
        case let .percent(value): value
        }
    }
}

public struct CodexModelsCost: Codable, Equatable, Sendable {
    public let knownAmount: Decimal
    public let pricedTokens: Int64
    public let unpricedTokens: Int64
    public let currencyCode: String

    public init(
        knownAmount: Decimal,
        pricedTokens: Int64,
        unpricedTokens: Int64,
        currencyCode: String = "USD")
    {
        self.knownAmount = knownAmount
        self.pricedTokens = pricedTokens
        self.unpricedTokens = unpricedTokens
        self.currencyCode = currencyCode
    }

    public static let zero = Self(knownAmount: 0, pricedTokens: 0, unpricedTokens: 0)

    public var coverage: Double {
        let total = self.pricedTokens + self.unpricedTokens
        return total == 0 ? 1 : Double(self.pricedTokens) / Double(total)
    }

    public func adding(_ other: Self) -> Self {
        Self(
            knownAmount: self.knownAmount + other.knownAmount,
            pricedTokens: self.pricedTokens + other.pricedTokens,
            unpricedTokens: self.unpricedTokens + other.unpricedTokens,
            currencyCode: self.currencyCode)
    }
}

public struct CodexModelsUsageFragment: Equatable, Sendable {
    public let workspaceID: String
    public let sessionID: String
    public let day: Date
    public let timestamp: Date
    public let rawModelID: String
    public let inputTokens: Int64
    public let cachedInputTokens: Int64
    public let outputTokens: Int64
    public let reasoningTokens: Int64?
    public let costNanos: Int64?
    public let unpricedTokens: Int64

    public init(
        workspaceID: String,
        sessionID: String,
        day: Date,
        timestamp: Date? = nil,
        rawModelID: String,
        inputTokens: Int64,
        cachedInputTokens: Int64,
        outputTokens: Int64,
        reasoningTokens: Int64? = nil,
        costNanos: Int64?,
        unpricedTokens: Int64? = nil)
    {
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.day = day
        self.timestamp = timestamp ?? day
        self.rawModelID = rawModelID
        self.inputTokens = max(0, inputTokens)
        self.cachedInputTokens = min(max(0, cachedInputTokens), max(0, inputTokens))
        self.outputTokens = max(0, outputTokens)
        self.reasoningTokens = reasoningTokens.map { min(max(0, $0), max(0, outputTokens)) }
        self.costNanos = costNanos
        let totalTokens = self.inputTokens + self.outputTokens
        let defaultUnpricedTokens = costNanos == nil ? totalTokens : 0
        self.unpricedTokens = min(max(0, unpricedTokens ?? defaultUnpricedTokens), totalTokens)
    }

    public var totalTokens: Int64 {
        self.inputTokens + self.outputTokens
    }
}

public struct CodexModelsDailyBucket: Codable, Equatable, Identifiable, Sendable {
    public let day: Date
    public let interval: DateInterval?
    public let tokens: Int64
    public let sessionIDs: [String]
    public let sessionReferenceIDs: [String]
    public let cost: CodexModelsCost

    public var id: Date {
        self.day
    }

    public var sessionReferences: Int {
        self.sessionReferenceIDs.count
    }

    public init(
        day: Date,
        interval: DateInterval? = nil,
        tokens: Int64,
        sessionIDs: [String],
        sessionReferenceIDs: [String]? = nil,
        cost: CodexModelsCost)
    {
        self.day = day
        self.interval = interval
        self.tokens = tokens
        self.sessionIDs = sessionIDs
        self.sessionReferenceIDs = sessionReferenceIDs ?? sessionIDs
        self.cost = cost
    }

    private enum CodingKeys: String, CodingKey {
        case day
        case interval
        case tokens
        case sessionIDs
        case sessionReferenceIDs
        case cost
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.day = try container.decode(Date.self, forKey: .day)
        self.interval = try container.decodeIfPresent(DateInterval.self, forKey: .interval)
        self.tokens = try container.decode(Int64.self, forKey: .tokens)
        self.sessionIDs = try container.decode([String].self, forKey: .sessionIDs)
        self.sessionReferenceIDs = try container.decodeIfPresent([String].self, forKey: .sessionReferenceIDs)
            ?? self.sessionIDs
        self.cost = try container.decode(CodexModelsCost.self, forKey: .cost)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.day, forKey: .day)
        try container.encodeIfPresent(self.interval, forKey: .interval)
        try container.encode(self.tokens, forKey: .tokens)
        try container.encode(self.sessionIDs, forKey: .sessionIDs)
        try container.encode(self.sessionReferenceIDs, forKey: .sessionReferenceIDs)
        try container.encode(self.cost, forKey: .cost)
    }

    public var effectiveInterval: DateInterval {
        self.interval ?? DateInterval(start: self.day, duration: 24 * 60 * 60)
    }
}

public struct CodexModelsRow: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let rawAliases: [String]
    public let inputTokens: Int64
    public let cachedInputTokens: Int64
    public let outputTokens: Int64
    public let reasoningTokens: Int64?
    public let totalTokens: Int64
    public let share: Double
    public let sessionReferences: Int
    public let cost: CodexModelsCost
    public let previousTotalTokens: Int64?
    public let previousCost: CodexModelsCost?
    public let previousSessionReferences: Int?
    public let associatedSessionIDs: [String]?
    public let tokenComparison: CodexModelsComparison
    public let costComparison: CodexModelsComparison
    public let sessionReferenceComparison: CodexModelsComparison

    public init(
        id: String,
        displayName: String,
        rawAliases: [String],
        inputTokens: Int64,
        cachedInputTokens: Int64,
        outputTokens: Int64,
        reasoningTokens: Int64?,
        totalTokens: Int64,
        share: Double,
        sessionReferences: Int,
        cost: CodexModelsCost,
        previousTotalTokens: Int64? = nil,
        previousCost: CodexModelsCost? = nil,
        previousSessionReferences: Int? = nil,
        associatedSessionIDs: [String]? = nil,
        tokenComparison: CodexModelsComparison,
        costComparison: CodexModelsComparison,
        sessionReferenceComparison: CodexModelsComparison)
    {
        self.id = id
        self.displayName = displayName
        self.rawAliases = rawAliases
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.totalTokens = totalTokens
        self.share = share
        self.sessionReferences = sessionReferences
        self.cost = cost
        self.previousTotalTokens = previousTotalTokens
        self.previousCost = previousCost
        self.previousSessionReferences = previousSessionReferences
        self.associatedSessionIDs = associatedSessionIDs
        self.tokenComparison = tokenComparison
        self.costComparison = costComparison
        self.sessionReferenceComparison = sessionReferenceComparison
    }

    public func metricValue(_ metric: CodexModelsMetric) -> Double {
        switch metric {
        case .tokens: Double(self.totalTokens)
        case .knownCost: NSDecimalNumber(decimal: self.cost.knownAmount).doubleValue
        case .sessionReferences: Double(self.sessionReferences)
        }
    }

    public func comparison(_ metric: CodexModelsMetric) -> CodexModelsComparison {
        switch metric {
        case .tokens: self.tokenComparison
        case .knownCost: self.costComparison
        case .sessionReferences: self.sessionReferenceComparison
        }
    }
}

public enum CodexModelsParityDimension: String, Codable, CaseIterable, Sendable {
    case totalTokens = "total_tokens"
    case modelIdentities = "model_identities"
    case knownCost = "known_cost"
    case pricingCoverage = "pricing_coverage"
    case activeModelCount = "active_model_count"
    case topModel = "top_model"
    case comparisons
    case sessionReferences = "session_references"
    case modelTokens = "model_tokens"
    case modelKnownCost = "model_known_cost"
    case modelPricingCoverage = "model_pricing_coverage"
    case modelSessionReferences = "model_session_references"
}

public struct CodexModelsRolloutDiagnostics: Codable, Equatable, Sendable {
    public let legacyTotalTokens: Int64
    public let revisedTotalTokens: Int64
    public let legacyModelIDs: [String]
    public let revisedModelIDs: [String]
    public let mismatches: [String]
    public let mismatchDimensions: [CodexModelsParityDimension]?

    public init(
        legacyTotalTokens: Int64,
        revisedTotalTokens: Int64,
        legacyModelIDs: [String],
        revisedModelIDs: [String],
        mismatches: [String],
        mismatchDimensions: [CodexModelsParityDimension]? = nil)
    {
        self.legacyTotalTokens = legacyTotalTokens
        self.revisedTotalTokens = revisedTotalTokens
        self.legacyModelIDs = legacyModelIDs
        self.revisedModelIDs = revisedModelIDs
        self.mismatches = mismatches
        self.mismatchDimensions = mismatchDimensions
    }

    public var isMatched: Bool {
        self.mismatches.isEmpty
    }
}

public struct CodexModelsAnalyticsSnapshot: Codable, Equatable, Sendable {
    public let scopeID: String?
    public let generatedAt: Date
    public let indexRevision: String
    public let currentInterval: DateInterval
    public let previousInterval: DateInterval
    /// Nil only when decoding a snapshot written before period completeness was persisted.
    public let currentIsComplete: Bool?
    /// Nil only when decoding a snapshot written before period completeness was persisted.
    public let previousIsComplete: Bool?
    public let totalTokens: Int64
    public let cost: CodexModelsCost
    public let activeModelCount: Int
    public let previousActiveModelCount: Int?
    public let newlyActiveModelCount: Int?
    public let uniqueSessionCount: Int
    public let sessionReferenceTotal: Int
    public let previousSessionReferenceTotal: Int?
    public let tokenComparison: CodexModelsComparison
    public let costComparison: CodexModelsComparison
    public let sessionReferenceComparison: CodexModelsComparison?
    public let rows: [CodexModelsRow]
    public let daily: [CodexModelsDailyBucket]
    public let dailyByModel: [String: [CodexModelsDailyBucket]]
    public let diagnostics: CodexModelsRolloutDiagnostics

    public func totalValue(_ metric: CodexModelsMetric) -> Double {
        switch metric {
        case .tokens: Double(self.totalTokens)
        case .knownCost: NSDecimalNumber(decimal: self.cost.knownAmount).doubleValue
        case .sessionReferences: Double(self.sessionReferenceTotal)
        }
    }

    public func share(of row: CodexModelsRow, metric: CodexModelsMetric) -> Double {
        let total = self.totalValue(metric)
        return total == 0 ? 0 : row.metricValue(metric) / total
    }

    public func comparison(_ metric: CodexModelsMetric) -> CodexModelsComparison {
        switch metric {
        case .tokens: self.tokenComparison
        case .knownCost: self.costComparison
        case .sessionReferences: self.sessionReferenceComparison ?? .unavailable
        }
    }

    public func invariantViolations() -> [String] {
        var failures: [String] = []
        if self.rows.reduce(Int64.zero, { $0 + $1.totalTokens }) != self.totalTokens {
            failures.append("summary_tokens")
        }
        let rowCost = self.rows.reduce(CodexModelsCost.zero) { $0.adding($1.cost) }
        if rowCost != self.cost { failures.append("cost_coverage") }
        if self.rows.count != self.activeModelCount { failures.append("active_models") }
        if self.rows.reduce(0, { $0 + $1.sessionReferences }) != self.sessionReferenceTotal {
            failures.append("session_references")
        }
        if self.daily.reduce(Int64.zero, { $0 + $1.tokens }) != self.totalTokens {
            failures.append("timeline_tokens")
        }
        return failures
    }
}

public struct CodexModelsAnalyticsPayload: Codable, Equatable, Sendable {
    public let allWorkspaces: CodexModelsAnalyticsSnapshot
    public let workspaces: [String: CodexModelsAnalyticsSnapshot]

    public func snapshot(workspaceID: String?) -> CodexModelsAnalyticsSnapshot {
        guard let workspaceID else { return self.allWorkspaces }
        return self.workspaces[workspaceID] ?? self.allWorkspaces
    }
}

public struct CodexModelsAnalyticsSource: Sendable {
    public let current: [CodexModelsUsageFragment]
    public let previous: [CodexModelsUsageFragment]

    public init(current: [CodexModelsUsageFragment], previous: [CodexModelsUsageFragment]) {
        self.current = current
        self.previous = previous
    }
}

public struct CodexModelsAnalyticsPeriods: Sendable {
    public let current: DateInterval
    public let previous: DateInterval

    public init(current: DateInterval, previous: DateInterval) {
        self.current = current
        self.previous = previous
    }
}

public struct CodexModelsAnalyticsRevision: Sendable {
    public let generatedAt: Date
    public let indexRevision: String

    public init(generatedAt: Date, indexRevision: String) {
        self.generatedAt = generatedAt
        self.indexRevision = indexRevision
    }
}

public struct CodexModelsLegacyModelBaseline: Sendable {
    public let modelID: String
    public let totalTokens: Int64?
    public let knownCost: Decimal?
    public let pricedTokens: Int64?
    public let unpricedTokens: Int64?
    public let sessionReferences: Int?

    public init(
        modelID: String,
        totalTokens: Int64? = nil,
        knownCost: Decimal? = nil,
        pricedTokens: Int64? = nil,
        unpricedTokens: Int64? = nil,
        sessionReferences: Int? = nil)
    {
        self.modelID = modelID
        self.totalTokens = totalTokens
        self.knownCost = knownCost
        self.pricedTokens = pricedTokens
        self.unpricedTokens = unpricedTokens
        self.sessionReferences = sessionReferences
    }
}

public struct CodexModelsLegacyBaseline: Sendable {
    public let totalTokens: Int64
    public let modelIDs: [String]
    public let knownCost: Decimal?
    public let pricedTokens: Int64?
    public let unpricedTokens: Int64?
    public let activeModelCount: Int?
    public let topModelID: String?
    public let sessionReferenceTotal: Int?
    public let previousTotalTokens: Int64?
    public let previousKnownCost: Decimal?
    public let previousUnpricedTokens: Int64?
    public let previousSessionReferenceTotal: Int?
    public let currentModels: [CodexModelsLegacyModelBaseline]?
    public let previousModels: [CodexModelsLegacyModelBaseline]?

    public init(
        totalTokens: Int64,
        modelIDs: [String],
        knownCost: Decimal? = nil,
        pricedTokens: Int64? = nil,
        unpricedTokens: Int64? = nil,
        activeModelCount: Int? = nil,
        topModelID: String? = nil,
        sessionReferenceTotal: Int? = nil,
        previousTotalTokens: Int64? = nil,
        previousKnownCost: Decimal? = nil,
        previousUnpricedTokens: Int64? = nil,
        previousSessionReferenceTotal: Int? = nil,
        currentModels: [CodexModelsLegacyModelBaseline]? = nil,
        previousModels: [CodexModelsLegacyModelBaseline]? = nil)
    {
        self.totalTokens = totalTokens
        self.modelIDs = modelIDs
        self.knownCost = knownCost
        self.pricedTokens = pricedTokens
        self.unpricedTokens = unpricedTokens
        self.activeModelCount = activeModelCount
        self.topModelID = topModelID
        self.sessionReferenceTotal = sessionReferenceTotal
        self.previousTotalTokens = previousTotalTokens
        self.previousKnownCost = previousKnownCost
        self.previousUnpricedTokens = previousUnpricedTokens
        self.previousSessionReferenceTotal = previousSessionReferenceTotal
        self.currentModels = currentModels
        self.previousModels = previousModels
    }
}

public struct CodexModelsAnalyticsRequest: Sendable {
    public let source: CodexModelsAnalyticsSource
    public let scopeID: String?
    public let periods: CodexModelsAnalyticsPeriods
    public let revision: CodexModelsAnalyticsRevision
    public let legacy: CodexModelsLegacyBaseline
    public let currentIsComplete: Bool
    public let previousIsComplete: Bool

    public init(
        source: CodexModelsAnalyticsSource,
        scopeID: String?,
        periods: CodexModelsAnalyticsPeriods,
        revision: CodexModelsAnalyticsRevision,
        legacy: CodexModelsLegacyBaseline,
        currentIsComplete: Bool = true,
        previousIsComplete: Bool = true)
    {
        self.source = source
        self.scopeID = scopeID
        self.periods = periods
        self.revision = revision
        self.legacy = legacy
        self.currentIsComplete = currentIsComplete
        self.previousIsComplete = previousIsComplete
    }
}

public struct CodexModelsAnalyticsBuilder: Sendable {
    public init() {}

    public func build(_ request: CodexModelsAnalyticsRequest) -> CodexModelsAnalyticsSnapshot {
        let current = self.filtered(
            request.source.current,
            scopeID: request.scopeID,
            interval: request.periods.current)
        let previous = self.filtered(
            request.source.previous,
            scopeID: request.scopeID,
            interval: request.periods.previous)
        let currentGroups = Dictionary(grouping: current) { self.canonicalID($0.rawModelID) }
        let previousGroups = Dictionary(grouping: previous) { self.canonicalID($0.rawModelID) }
        let comparisonIsComplete = request.currentIsComplete && request.previousIsComplete
        let totalTokens = current.reduce(Int64.zero) { $0 + $1.totalTokens }
        let previousTokens = previous.reduce(Int64.zero) { $0 + $1.totalTokens }
        let previousSessionReferenceTotal = previousGroups.values.reduce(0) { partial, events in
            partial + Set(events.map(\.sessionID)).count
        }
        let rows = self.makeRows(
            currentGroups: currentGroups,
            previousGroups: previousGroups,
            totalTokens: totalTokens,
            previousIsComplete: request.previousIsComplete,
            comparisonIsComplete: comparisonIsComplete)

        let totalCost = rows.reduce(CodexModelsCost.zero) { $0.adding($1.cost) }
        let previousCost = self.cost(previous)
        let sessionReferenceTotal = rows.reduce(0) { $0 + $1.sessionReferences }
        let tokenComparison = CodexModelsComparison.make(
            current: Double(totalTokens),
            previous: Double(previousTokens),
            previousIsComplete: comparisonIsComplete)
        let costComparison = CodexModelsComparison.make(
            current: NSDecimalNumber(decimal: totalCost.knownAmount).doubleValue,
            previous: NSDecimalNumber(decimal: previousCost.knownAmount).doubleValue,
            previousIsComplete: comparisonIsComplete
                && totalCost.unpricedTokens == 0
                && previousCost.unpricedTokens == 0)
        let sessionReferenceComparison = CodexModelsComparison.make(
            current: Double(sessionReferenceTotal),
            previous: Double(previousSessionReferenceTotal),
            previousIsComplete: comparisonIsComplete)
        let newlyActiveModelCount: Int? = comparisonIsComplete
            ? currentGroups.keys.count(where: { previousGroups[$0] == nil })
            : nil
        let revisedIDs = rows.map(\.id).sorted()
        let mismatchDimensions = self.parityMismatches(ParityInputs(
            request: request,
            currentGroups: currentGroups,
            previousGroups: previousGroups,
            rows: rows,
            totalTokens: totalTokens,
            totalCost: totalCost,
            sessionReferenceTotal: sessionReferenceTotal,
            comparisonIsComplete: comparisonIsComplete,
            tokenComparison: tokenComparison,
            costComparison: costComparison,
            sessionReferenceComparison: sessionReferenceComparison))

        let daily = self.dailyBuckets(current)
        let dailyByModel = currentGroups.mapValues { self.dailyBuckets($0) }
        return CodexModelsAnalyticsSnapshot(
            scopeID: request.scopeID,
            generatedAt: request.revision.generatedAt,
            indexRevision: request.revision.indexRevision,
            currentInterval: request.periods.current,
            previousInterval: request.periods.previous,
            currentIsComplete: request.currentIsComplete,
            previousIsComplete: request.previousIsComplete,
            totalTokens: totalTokens,
            cost: totalCost,
            activeModelCount: rows.count,
            previousActiveModelCount: request.previousIsComplete ? previousGroups.count : nil,
            newlyActiveModelCount: newlyActiveModelCount,
            uniqueSessionCount: Set(current.map(\.sessionID)).count,
            sessionReferenceTotal: sessionReferenceTotal,
            previousSessionReferenceTotal: request.previousIsComplete ? previousSessionReferenceTotal : nil,
            tokenComparison: tokenComparison,
            costComparison: costComparison,
            sessionReferenceComparison: sessionReferenceComparison,
            rows: rows,
            daily: daily,
            dailyByModel: dailyByModel,
            diagnostics: CodexModelsRolloutDiagnostics(
                legacyTotalTokens: request.legacy.totalTokens,
                revisedTotalTokens: totalTokens,
                legacyModelIDs: request.legacy.modelIDs.sorted(),
                revisedModelIDs: revisedIDs,
                mismatches: mismatchDimensions.map(\.rawValue),
                mismatchDimensions: mismatchDimensions))
    }

    private func makeRows(
        currentGroups: [String: [CodexModelsUsageFragment]],
        previousGroups: [String: [CodexModelsUsageFragment]],
        totalTokens: Int64,
        previousIsComplete: Bool,
        comparisonIsComplete: Bool) -> [CodexModelsRow]
    {
        currentGroups.map { modelID, events in
            let earlier = previousGroups[modelID, default: []]
            let tokens = events.reduce(Int64.zero) { $0 + $1.totalTokens }
            let previousModelTokens = earlier.reduce(Int64.zero) { $0 + $1.totalTokens }
            let cost = self.cost(events)
            let previousCost = self.cost(earlier)
            let sessionReferences = Set(events.map(\.sessionID)).count
            let previousSessionReferences = Set(earlier.map(\.sessionID)).count
            let reasoningValues = events.compactMap(\.reasoningTokens)
            return CodexModelsRow(
                id: modelID,
                displayName: CostUsagePricing.codexDisplayLabel(model: modelID) ?? modelID,
                rawAliases: Array(Set(events.map(\.rawModelID))).sorted(),
                inputTokens: events.reduce(0) { $0 + $1.inputTokens },
                cachedInputTokens: events.reduce(0) { $0 + $1.cachedInputTokens },
                outputTokens: events.reduce(0) { $0 + $1.outputTokens },
                reasoningTokens: reasoningValues.isEmpty ? nil : reasoningValues.reduce(0, +),
                totalTokens: tokens,
                share: totalTokens == 0 ? 0 : Double(tokens) / Double(totalTokens),
                sessionReferences: sessionReferences,
                cost: cost,
                previousTotalTokens: previousIsComplete ? previousModelTokens : nil,
                previousCost: previousIsComplete ? previousCost : nil,
                previousSessionReferences: previousIsComplete ? previousSessionReferences : nil,
                associatedSessionIDs: Array(Set(events.map(\.sessionID))).sorted(),
                tokenComparison: .make(
                    current: Double(tokens),
                    previous: Double(previousModelTokens),
                    previousIsComplete: comparisonIsComplete),
                costComparison: .make(
                    current: NSDecimalNumber(decimal: cost.knownAmount).doubleValue,
                    previous: NSDecimalNumber(decimal: previousCost.knownAmount).doubleValue,
                    previousIsComplete: comparisonIsComplete
                        && cost.unpricedTokens == 0
                        && previousCost.unpricedTokens == 0),
                sessionReferenceComparison: .make(
                    current: Double(sessionReferences),
                    previous: Double(previousSessionReferences),
                    previousIsComplete: comparisonIsComplete))
        }
        .sorted {
            if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
            if $0.sessionReferences != $1.sessionReferences { return $0.sessionReferences > $1.sessionReferences }
            return $0.id < $1.id
        }
    }

    private struct ParityInputs {
        let request: CodexModelsAnalyticsRequest
        let currentGroups: [String: [CodexModelsUsageFragment]]
        let previousGroups: [String: [CodexModelsUsageFragment]]
        let rows: [CodexModelsRow]
        let totalTokens: Int64
        let totalCost: CodexModelsCost
        let sessionReferenceTotal: Int
        let comparisonIsComplete: Bool
        let tokenComparison: CodexModelsComparison
        let costComparison: CodexModelsComparison
        let sessionReferenceComparison: CodexModelsComparison
    }

    private func parityMismatches(_ inputs: ParityInputs) -> [CodexModelsParityDimension] {
        var dimensions: [CodexModelsParityDimension] = []
        let request = inputs.request
        if request.legacy.totalTokens != inputs.totalTokens { dimensions.append(.totalTokens) }
        let legacyIDs = Array(Set(request.legacy.modelIDs.map { self.canonicalID($0) })).sorted()
        if legacyIDs != inputs.rows.map(\.id).sorted() { dimensions.append(.modelIdentities) }
        if let knownCost = request.legacy.knownCost, knownCost != inputs.totalCost.knownAmount {
            dimensions.append(.knownCost)
        }
        if let priced = request.legacy.pricedTokens,
           let unpriced = request.legacy.unpricedTokens,
           priced != inputs.totalCost.pricedTokens || unpriced != inputs.totalCost.unpricedTokens
        {
            dimensions.append(.pricingCoverage)
        }
        if let count = request.legacy.activeModelCount, count != inputs.rows.count {
            dimensions.append(.activeModelCount)
        }
        if let topModelID = request.legacy.topModelID,
           self.canonicalID(topModelID) != inputs.rows.first?.id
        {
            dimensions.append(.topModel)
        }
        if let references = request.legacy.sessionReferenceTotal, references != inputs.sessionReferenceTotal {
            dimensions.append(.sessionReferences)
        }
        if inputs.comparisonIsComplete,
           self.legacyComparisonsMismatch(
               request.legacy,
               tokenComparison: inputs.tokenComparison,
               costComparison: inputs.costComparison,
               sessionReferenceComparison: inputs.sessionReferenceComparison)
        {
            dimensions.append(.comparisons)
        }
        let modelDimensions = self.modelParityMismatches(
            legacy: request.currentIsComplete ? request.legacy.currentModels : nil,
            revised: inputs.currentGroups)
            .union(self.modelParityMismatches(
                legacy: request.previousIsComplete ? request.legacy.previousModels : nil,
                revised: inputs.previousGroups))
        for dimension in [
            CodexModelsParityDimension.modelTokens,
            .modelKnownCost,
            .modelPricingCoverage,
            .modelSessionReferences,
        ] where modelDimensions.contains(dimension) {
            dimensions.append(dimension)
        }
        return dimensions
    }

    private func legacyComparisonsMismatch(
        _ legacy: CodexModelsLegacyBaseline,
        tokenComparison: CodexModelsComparison,
        costComparison: CodexModelsComparison,
        sessionReferenceComparison: CodexModelsComparison) -> Bool
    {
        guard let previousTokens = legacy.previousTotalTokens else { return false }
        let legacyToken = CodexModelsComparison.make(
            current: Double(legacy.totalTokens),
            previous: Double(previousTokens))
        let legacyCost = legacy.knownCost.flatMap { currentCost in
            legacy.previousKnownCost.map { previousCost in
                CodexModelsComparison.make(
                    current: NSDecimalNumber(decimal: currentCost).doubleValue,
                    previous: NSDecimalNumber(decimal: previousCost).doubleValue,
                    previousIsComplete: legacy.previousUnpricedTokens == 0)
            }
        }
        let legacySessions = legacy.sessionReferenceTotal.flatMap { currentReferences in
            legacy.previousSessionReferenceTotal.map { previousReferences in
                CodexModelsComparison.make(current: Double(currentReferences), previous: Double(previousReferences))
            }
        }
        return legacyToken != tokenComparison
            || legacyCost.map { $0 != costComparison } == true
            || legacySessions.map { $0 != sessionReferenceComparison } == true
    }

    public func canonicalID(_ rawID: String) -> String {
        CostUsagePricing.normalizeCodexModel(
            rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private func modelParityMismatches(
        legacy: [CodexModelsLegacyModelBaseline]?,
        revised: [String: [CodexModelsUsageFragment]]) -> Set<CodexModelsParityDimension>
    {
        guard let legacy else { return [] }
        let normalized = Dictionary(grouping: legacy) { self.canonicalID($0.modelID) }
        var mismatches: Set<CodexModelsParityDimension> = []
        for (modelID, legacyRows) in normalized {
            guard let revisedFragments = revised[modelID] else { continue }
            let revisedTokens = revisedFragments.reduce(Int64.zero) { $0 + $1.totalTokens }
            let revisedCost = self.cost(revisedFragments)
            let revisedSessionReferences = Set(revisedFragments.map(\.sessionID)).count
            let legacyTokens = self.sumIfComplete(legacyRows.map(\.totalTokens))
            let legacyKnownCost = self.sumIfComplete(legacyRows.map(\.knownCost))
            let legacyPricedTokens = self.sumIfComplete(legacyRows.map(\.pricedTokens))
            let legacyUnpricedTokens = self.sumIfComplete(legacyRows.map(\.unpricedTokens))
            // Distinct session counts cannot be safely summed across alias rows because
            // the underlying session sets may overlap. Production baselines canonicalize
            // first, so an exact value remains available there.
            let legacySessionReferences = legacyRows.count == 1 ? legacyRows[0].sessionReferences : nil

            if let legacyTokens, legacyTokens != revisedTokens {
                mismatches.insert(.modelTokens)
            }
            if let legacyKnownCost, legacyKnownCost != revisedCost.knownAmount {
                mismatches.insert(.modelKnownCost)
            }
            if legacyPricedTokens.map({ $0 != revisedCost.pricedTokens }) == true
                || legacyUnpricedTokens.map({ $0 != revisedCost.unpricedTokens }) == true
            {
                mismatches.insert(.modelPricingCoverage)
            }
            if let legacySessionReferences, legacySessionReferences != revisedSessionReferences {
                mismatches.insert(.modelSessionReferences)
            }
        }
        return mismatches
    }

    private func sumIfComplete(_ values: [Int64?]) -> Int64? {
        let available = values.compactMap(\.self)
        return available.count == values.count ? available.reduce(0, +) : nil
    }

    private func sumIfComplete(_ values: [Decimal?]) -> Decimal? {
        let available = values.compactMap(\.self)
        return available.count == values.count ? available.reduce(0, +) : nil
    }

    private func filtered(
        _ fragments: [CodexModelsUsageFragment],
        scopeID: String?,
        interval: DateInterval) -> [CodexModelsUsageFragment]
    {
        fragments.filter { fragment in
            (scopeID == nil || fragment.workspaceID == scopeID)
                && fragment.timestamp >= interval.start
                && fragment.timestamp < interval.end
        }
    }

    private func cost(_ fragments: [CodexModelsUsageFragment]) -> CodexModelsCost {
        fragments.reduce(.zero) { partial, fragment in
            let unpriced = fragment.unpricedTokens
            let priced = fragment.totalTokens - unpriced
            let amount = fragment.costNanos.map { Decimal($0) / 1_000_000_000 } ?? 0
            return partial.adding(CodexModelsCost(
                knownAmount: amount,
                pricedTokens: priced,
                unpricedTokens: unpriced))
        }
    }

    private func dailyBuckets(_ fragments: [CodexModelsUsageFragment]) -> [CodexModelsDailyBucket] {
        let calendar = Calendar.current
        return Dictionary(grouping: fragments, by: \.day).map { day, values in
            let start = calendar.startOfDay(for: day)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(24 * 60 * 60)
            return CodexModelsDailyBucket(
                day: start,
                interval: DateInterval(start: start, end: end),
                tokens: values.reduce(0) { $0 + $1.totalTokens },
                sessionIDs: Array(Set(values.map(\.sessionID))).sorted(),
                sessionReferenceIDs: Array(Set(values.map {
                    "\($0.sessionID)\u{1F}\(self.canonicalID($0.rawModelID))"
                })).sorted(),
                cost: self.cost(values))
        }
        .sorted { $0.day < $1.day }
    }
}
