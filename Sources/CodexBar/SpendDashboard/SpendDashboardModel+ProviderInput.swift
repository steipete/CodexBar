import CodexBarCore
import Foundation

extension SpendDashboardModel {
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
}
