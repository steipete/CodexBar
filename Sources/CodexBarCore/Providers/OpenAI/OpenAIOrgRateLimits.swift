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
        let manual = Dictionary(uniqueKeysWithValues: self.manual.map {
            ($0.model, OpenAIOrgRateLimits.Limit(
                tokensPerMinute: $0.tokensPerMinute, requestsPerMinute: $0.requestsPerMinute))
        })
        return Self.match(model, in: manual)
    }

    public func projectCap(for model: String) -> OpenAIOrgRateLimits.Limit? {
        Self.match(model, in: self.projectCaps?.byModel ?? [:])
    }

    private static func match(_ model: String, in limits: [String: OpenAIOrgRateLimits.Limit])
        -> OpenAIOrgRateLimits.Limit?
    {
        if let exact = limits[model] { return exact }
        // Only dated snapshots inherit a family limit (gpt-5 covers gpt-5-2025-08-07, gpt-4 covers gpt-4-0613);
        // distinct models such as gpt-5-mini have their own limits.
        let family = limits.keys.filter { key in
            model.hasPrefix(key + "-") && Self.isSnapshotSuffix(model.dropFirst(key.count + 1))
        }.max { $0.count < $1.count }
        return family.flatMap { limits[$0] }
    }

    private static func isSnapshotSuffix(_ suffix: Substring) -> Bool {
        suffix.wholeMatch(of: /\d{4}-\d{2}-\d{2}|\d{4}/) != nil
    }
}

public struct OpenAIOrgLimitUtilization: Sendable, Equatable {
    public let limit: OpenAIOrgRateLimits.Limit
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
        guard case let .model(name) = filter, let limit = limits.resolve(name) else { return nil }
        let points = self.series(for: filter)
        let latest = points.first { $0.start == self.reportingFrontier }
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
