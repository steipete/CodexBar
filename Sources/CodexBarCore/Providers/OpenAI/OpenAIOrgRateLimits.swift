import Foundation

public struct OpenAIOrgRateLimits: Sendable, Equatable {
    public struct Limit: Sendable, Equatable {
        public let tokensPerMinute: Int
        public let requestsPerMinute: Int?

        public init(tokensPerMinute: Int, requestsPerMinute: Int? = nil) {
            self.tokensPerMinute = tokensPerMinute
            self.requestsPerMinute = requestsPerMinute
        }
    }

    public let byModel: [String: Limit]
    public let projectsSampled: Int
    public let truncated: Bool
    public let fetchedAt: Date

    public init(byModel: [String: Limit], projectsSampled: Int, truncated: Bool, fetchedAt: Date) {
        self.byModel = byModel
        self.projectsSampled = projectsSampled
        self.truncated = truncated
        self.fetchedAt = fetchedAt
    }
}

public struct OpenAIOrgLimitResolver: Sendable {
    public let manual: [ProviderModelRateLimit]
    public let projectCaps: OpenAIOrgRateLimits?

    public init(manual: [ProviderModelRateLimit], projectCaps: OpenAIOrgRateLimits?) {
        self.manual = ProviderModelRateLimit.validated(manual)
        self.projectCaps = projectCaps
    }

    public func resolve(_ model: String) -> OpenAIOrgRateLimits.Limit? {
        guard let key = self.manualLimitKey(for: model),
              let entry = self.manual.first(where: { $0.model == key }) else { return nil }
        return .init(tokensPerMinute: entry.tokensPerMinute, requestsPerMinute: entry.requestsPerMinute)
    }

    public func manualLimitKey(for model: String) -> String? {
        Self.matchKey(model, in: self.manual.map(\.model))
    }

    public func projectCap(for model: String) -> OpenAIOrgRateLimits.Limit? {
        Self.match(model, in: self.projectCaps?.byModel ?? [:])
    }

    private static func match(_ model: String, in limits: [String: OpenAIOrgRateLimits.Limit])
        -> OpenAIOrgRateLimits.Limit?
    {
        self.matchKey(model, in: Array(limits.keys)).flatMap { limits[$0] }
    }

    private static func matchKey(_ model: String, in keys: [String]) -> String? {
        if keys.contains(model) { return model }
        // Only dated snapshots inherit a family limit (gpt-5 covers gpt-5-2025-08-07, gpt-4 covers gpt-4-0613);
        // distinct models such as gpt-5-mini have their own limits.
        return keys.filter { key in
            model.hasPrefix(key + "-") && Self.isSnapshotSuffix(model.dropFirst(key.count + 1))
        }.max { $0.count < $1.count }
    }

    private static func isSnapshotSuffix(_ suffix: Substring) -> Bool {
        suffix.wholeMatch(of: /\d{4}-\d{2}-\d{2}|\d{4}/) != nil
    }
}

public struct OpenAIOrgLimitUtilization: Sendable, Equatable {
    public let limit: OpenAIOrgRateLimits.Limit
    public let pooledModels: [String]
    public let latestTPMPercent: Double
    public let peakTPMPercent: Double
    public let peakRPMPercent: Double?
}

extension OpenAILiveUsageSnapshot {
    public func utilization(
        for filter: OpenAILiveUsageModelFilter,
        limits: OpenAIOrgLimitResolver) -> OpenAIOrgLimitUtilization?
    {
        // Project-scoped usage is only a slice of the org-wide traffic that org limits apply to.
        guard self.projectID == nil else { return nil }
        guard case let .model(name) = filter,
              let key = limits.manualLimitKey(for: name), let limit = limits.resolve(name) else { return nil }
        let pooledModels = self.modelNames.filter { limits.manualLimitKey(for: $0) == key }
        let members = Set(pooledModels)
        let frontier = self.reportingFrontier
        let points = self.minutes.map { minute in
            let models = minute.models.filter { members.contains($0.name) }
            return (
                start: minute.start,
                limitCountedTokens: models.reduce(0) { $0 + $1.totalTokens - $1.batchTokens },
                limitCountedRequests: models.reduce(0) { $0 + $1.requests - $1.batchRequests },
                isPending: frontier.map { minute.start > $0 } ?? true)
        }
        let latest = points.first { $0.start == frontier }
        let reported = points.filter { !$0.isPending }
        // Typed intermediates keep older Swift toolchains from timing out on type-checking.
        let tpmLimit = Double(limit.tokensPerMinute)
        let latestTokens: Int = latest?.limitCountedTokens ?? 0
        let peakTokens: Int = reported.map(\.limitCountedTokens).max() ?? 0
        let peakRequests: Int = reported.map(\.limitCountedRequests).max() ?? 0
        var peakRPMPercent: Double?
        if let rpm = limit.requestsPerMinute, rpm > 0 {
            peakRPMPercent = Double(peakRequests) / Double(rpm) * 100
        }
        return OpenAIOrgLimitUtilization(
            limit: limit,
            pooledModels: pooledModels,
            latestTPMPercent: Double(latestTokens) / tpmLimit * 100,
            peakTPMPercent: Double(peakTokens) / tpmLimit * 100,
            peakRPMPercent: peakRPMPercent)
    }

    public func modelRows(limits: OpenAIOrgLimitResolver) -> [ModelRow] {
        self.modelRows.map { row in
            let utilization = self.utilization(for: .model(row.name), limits: limits)
            return ModelRow(
                name: row.name,
                latestTPM: row.latestTPM,
                peakTPM: row.peakTPM,
                totalTokens: row.totalTokens,
                requests: row.requests,
                tpmLimit: utilization?.limit.tokensPerMinute,
                rpmLimit: utilization?.limit.requestsPerMinute,
                projectCap: limits.projectCap(for: row.name)?.tokensPerMinute,
                peakTPMPercent: utilization?.peakTPMPercent,
                latestTPMPercent: utilization?.latestTPMPercent)
        }
    }

    public func highestUtilization(limits: OpenAIOrgLimitResolver) -> ModelRow? {
        self.modelRows(limits: limits).filter { $0.peakTPMPercent != nil }.max {
            let left = $0.peakTPMPercent ?? 0
            let right = $1.peakTPMPercent ?? 0
            return left == right ? $0.name > $1.name : left < right
        }
    }
}
