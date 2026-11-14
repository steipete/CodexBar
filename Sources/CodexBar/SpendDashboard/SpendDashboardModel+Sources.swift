import CodexBarCore
import Foundation

extension SpendDashboardModel {
    enum SourceKind: String, Sendable, Equatable {
        case native
        case openCodex
        case localHistory
        case communityPlugin
    }

    static let openCodexSourceID = "opencodex"
    struct ProviderInput: Sendable {
        let id: String
        let provider: ProviderInstanceID
        var displayName: String
        let modelProviderName: String
        var snapshot: CostUsageTokenSnapshot
        var retainedDetailSnapshot: CostUsageTokenSnapshot?
        let tokenActivityCache: CostUsageTokenActivityCache?

        init(
            id: String? = nil,
            provider: UsageProvider,
            displayName: String,
            modelProviderName: String? = nil,
            snapshot: CostUsageTokenSnapshot,
            tokenActivityCache: CostUsageTokenActivityCache? = nil,
            sourceKind: SpendDashboardModel.SourceKind = .native)
        {
            self.init(
                id: id,
                providerID: provider.instanceID,
                displayName: displayName,
                modelProviderName: modelProviderName,
                snapshot: snapshot,
                tokenActivityCache: tokenActivityCache,
                sourceKind: sourceKind)
        }

        init(
            id: String? = nil,
            providerID: ProviderInstanceID,
            displayName: String,
            modelProviderName: String? = nil,
            snapshot: CostUsageTokenSnapshot,
            tokenActivityCache: CostUsageTokenActivityCache? = nil,
            sourceKind: SpendDashboardModel.SourceKind = .native)
        {
            self.id = id ?? providerID.rawValue
            self.provider = providerID
            self.displayName = displayName
            self.modelProviderName = modelProviderName ?? displayName
            self.snapshot = snapshot.droppingQuotaSlices()
            self.tokenActivityCache = tokenActivityCache
            self.sourceKind = sourceKind
        }

        let sourceKind: SpendDashboardModel.SourceKind
    }

    struct SourceFilterItem: Identifiable, Equatable, Sendable {
        let id: String
        let displayName: String
    }

    struct ProviderRow: Identifiable, Equatable, Sendable {
        let id: String
        let rank: Int
        let provider: ProviderInstanceID
        let displayName: String
        let totalTokens: Int?
        let totalCost: Double?
        let coveredDayCount: Int
        let sourceKind: SourceKind

        let incompleteRequestCount: Int
        /// The spend shown is a floor: some requests could not be priced, or the scan that produced
        /// the rows stopped short. Surfaces must mark it rather than render it as an exact total.
        let costIsLowerBound: Bool
        /// The token total is a floor for the same reason.
        let tokensAreLowerBound: Bool

        init(
            id: String,
            rank: Int,
            provider: ProviderInstanceID,
            displayName: String,
            totalTokens: Int?,
            totalCost: Double?,
            coveredDayCount: Int,
            sourceKind: SourceKind = .native,
            incompleteRequestCount: Int = 0,
            costIsLowerBound: Bool = false,
            tokensAreLowerBound: Bool = false)
        {
            self.incompleteRequestCount = incompleteRequestCount
            self.costIsLowerBound = costIsLowerBound
            self.tokensAreLowerBound = tokensAreLowerBound
            self.id = id
            self.rank = rank
            self.provider = provider
            self.displayName = displayName
            self.totalTokens = totalTokens
            self.totalCost = totalCost
            self.coveredDayCount = coveredDayCount
            self.sourceKind = sourceKind
        }
    }

    struct TokenActivityPoint: Identifiable, Equatable, Sendable {
        let day: Date
        /// `nil` means at least one included source cannot establish coverage for this day.
        /// This must stay distinct from a proven zero so the heatmap does not fabricate inactivity.
        let totalTokens: Int?
        /// Whether at least one source scanned the day. A nil total with scanned contributors
        /// remains a visible gap when another source cannot establish its count or coverage.
        let isScanned: Bool

        init(day: Date, totalTokens: Int?, isScanned: Bool = true) {
            self.day = day
            self.totalTokens = totalTokens
            self.isScanned = isScanned
        }

        var id: Date {
            self.day
        }
    }

    struct DailyPoint: Identifiable, Equatable, Sendable {
        let sourceID: String
        let provider: ProviderInstanceID
        let providerName: String
        let day: Date
        let cost: Double
        let stackStart: Double
        let stackEnd: Double

        var id: String {
            "\(self.sourceID):\(Int(self.day.timeIntervalSince1970))"
        }
    }
}
