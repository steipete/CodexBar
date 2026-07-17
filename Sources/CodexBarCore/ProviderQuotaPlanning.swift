import Foundation

public struct QuotaPlanningResolutionInput: Sendable {
    public let usage: UsageSnapshot
    public let strategyID: String
    public let strategyKind: ProviderFetchKind
    public let observationFreshness: ProviderObservationFreshness

    public init(
        usage: UsageSnapshot,
        strategyID: String,
        strategyKind: ProviderFetchKind,
        observationFreshness: ProviderObservationFreshness)
    {
        self.usage = usage
        self.strategyID = strategyID
        self.strategyKind = strategyKind
        self.observationFreshness = observationFreshness
    }

    public init(result: ProviderFetchResult) {
        self.init(
            usage: result.usage,
            strategyID: result.strategyID,
            strategyKind: result.strategyKind,
            observationFreshness: result.observationFreshness)
    }
}

public struct ProviderQuotaPlanningCapability: Sendable {
    public typealias Resolver = @Sendable (QuotaPlanningResolutionInput) -> [QuotaPlanningPairSnapshot]

    private let resolver: Resolver

    public init(resolve: @escaping Resolver) {
        self.resolver = resolve
    }

    public func resolvePairs(for result: ProviderFetchResult) -> [QuotaPlanningPairSnapshot] {
        self.resolvePairs(input: QuotaPlanningResolutionInput(result: result))
    }

    public func resolvePairs(input: QuotaPlanningResolutionInput) -> [QuotaPlanningPairSnapshot] {
        guard input.observationFreshness == .live,
              !input.strategyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return []
        }

        let candidates = self.resolver(input).filter(Self.isInitialRolloutEligible)
        guard !candidates.isEmpty else { return [] }

        let pairIDCounts = Dictionary(grouping: candidates, by: { Self.normalized($0.id) })
            .mapValues(\.count)
        let metricIDCounts = Dictionary(
            grouping: candidates.flatMap { [Self.normalized($0.short.metricID), Self.normalized($0.long.metricID)] },
            by: { $0 })
            .mapValues(\.count)

        return candidates.filter { pair in
            let pairID = Self.normalized(pair.id)
            let shortMetricID = Self.normalized(pair.short.metricID)
            let longMetricID = Self.normalized(pair.long.metricID)
            return !pairID.isEmpty &&
                !shortMetricID.isEmpty &&
                !longMetricID.isEmpty &&
                shortMetricID != longMetricID &&
                pairIDCounts[pairID] == 1 &&
                metricIDCounts[shortMetricID] == 1 &&
                metricIDCounts[longMetricID] == 1
        }
    }

    public static func primarySecondaryPairs(
        usage: UsageSnapshot,
        pairID: String = "primary-secondary") -> [QuotaPlanningPairSnapshot]
    {
        guard let primary = usage.primary, let secondary = usage.secondary else { return [] }
        return [QuotaPlanningPairSnapshot(
            id: pairID,
            short: QuotaPlanningWindowSnapshot(metricID: "primary", window: primary),
            long: QuotaPlanningWindowSnapshot(metricID: "secondary", window: secondary))]
    }

    private static func isInitialRolloutEligible(_ pair: QuotaPlanningPairSnapshot) -> Bool {
        let short = pair.short
        let long = pair.long
        guard short.usageKnown,
              long.usageKnown,
              !short.window.isSyntheticPlaceholder,
              !long.window.isSyntheticPlaceholder,
              short.window.nextRegenPercent == nil,
              long.window.nextRegenPercent == nil,
              short.window.usedPercent.isFinite,
              long.window.usedPercent.isFinite,
              (0...100).contains(short.window.usedPercent),
              (0..<100).contains(long.window.usedPercent),
              let shortMinutes = short.window.windowMinutes,
              let longMinutes = long.window.windowMinutes,
              (240...360).contains(shortMinutes),
              longMinutes == 10080,
              short.window.resetsAt != nil,
              long.window.resetsAt != nil
        else {
            return false
        }
        return true
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
