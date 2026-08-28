import CodexBarCore
import Observation

struct MenuCardLiveSubtitle {
    let text: String
    let style: UsageMenuCardView.Model.SubtitleStyle
}

/// Updates values in an already-hosted card without rebuilding its tracked NSMenu.
@MainActor
@Observable
final class MenuCardRefreshMonitor {
    typealias ModelResolver = @MainActor (UsageProvider) -> UsageMenuCardView.Model?
    typealias ProviderRefreshStateResolver = @MainActor (UsageProvider) -> Bool

    private let resolveModel: ModelResolver
    private let isProviderRefreshActive: ProviderRefreshStateResolver
    /// Set while an all-providers refresh is running; individual cards freeze only while their
    /// provider has active refresh work.
    private var globalManualRefreshInFlight = false
    /// Providers with an individual manual refresh in flight. Concurrent entries are allowed so
    /// refreshing one provider does not stall or unfreeze another.
    private var manualRefreshProviders: Set<ProviderInstanceID> = []
    private var frozenManualRefreshModels: [ProviderInstanceID: UsageMenuCardView.Model] = [:]
    /// Core models published before optional enrichment finishes. These keep an already-hosted card on the
    /// refreshed quota if a later enrichment step temporarily changes the model's tracked layout.
    private var publishedManualRefreshModels: [ProviderInstanceID: UsageMenuCardView.Model] = [:]

    /// True while any manual refresh (global or per-provider) is running.
    var isManualRefreshInFlight: Bool {
        self.globalManualRefreshInFlight || !self.manualRefreshProviders.isEmpty
    }

    init(
        resolveModel: @escaping ModelResolver,
        isProviderRefreshActive: @escaping ProviderRefreshStateResolver)
    {
        self.resolveModel = resolveModel
        self.isProviderRefreshActive = isProviderRefreshActive
    }

    func beginManualRefresh(
        frozenModels: [UsageProvider: UsageMenuCardView.Model],
        provider: UsageProvider? = nil)
    {
        if let provider {
            self.frozenManualRefreshModels[provider.instanceID] = frozenModels[provider]
            self.manualRefreshProviders.insert(provider.instanceID)
        } else {
            self.frozenManualRefreshModels = Dictionary(
                uniqueKeysWithValues: frozenModels.map { ($0.key.instanceID, $0.value) })
            self.globalManualRefreshInFlight = true
        }
    }

    /// Balances a `beginManualRefresh` with the same `provider` argument (nil ends the global refresh).
    func endManualRefresh(for provider: UsageProvider? = nil) {
        if let provider {
            self.manualRefreshProviders.remove(provider.instanceID)
            self.frozenManualRefreshModels[provider.instanceID] = nil
            self.publishedManualRefreshModels[provider.instanceID] = nil
        } else {
            self.globalManualRefreshInFlight = false
            self.frozenManualRefreshModels.removeAll(keepingCapacity: true)
            self.publishedManualRefreshModels.removeAll(keepingCapacity: true)
        }
    }

    /// Ends a provider-scoped refresh only when the hosted card can adopt the resolved model without a rebuild.
    /// The published model stays pinned as a compatible fallback until the caller reaches its final reconciliation.
    @discardableResult
    func publishResolvedModelIfCompatible(for provider: UsageProvider) -> Bool {
        let instanceID = provider.instanceID
        guard self.manualRefreshProviders.contains(instanceID),
              let frozen = self.frozenManualRefreshModels[instanceID],
              let resolved = self.resolveModel(provider),
              frozen.hasCompatibleTrackedLayout(with: resolved)
        else {
            return false
        }

        self.manualRefreshProviders.remove(instanceID)
        self.frozenManualRefreshModels[instanceID] = nil
        self.publishedManualRefreshModels[instanceID] = resolved
        return true
    }

    func resetManualRefresh() {
        self.globalManualRefreshInFlight = false
        self.manualRefreshProviders.removeAll(keepingCapacity: true)
        self.frozenManualRefreshModels.removeAll(keepingCapacity: true)
        self.publishedManualRefreshModels.removeAll(keepingCapacity: true)
    }

    func isManualRefreshInFlight(for provider: UsageProvider) -> Bool {
        self.manualRefreshProviders.contains(provider.instanceID) ||
            (self.globalManualRefreshInFlight && self.isProviderRefreshActive(provider))
    }

    func model(
        for provider: UsageProvider,
        fallback: UsageMenuCardView.Model) -> UsageMenuCardView.Model
    {
        guard !self.isManualRefreshInFlight(for: provider) else {
            guard let frozen = self.frozenManualRefreshModels[provider.instanceID] else {
                return fallback
            }
            if fallback.hasCompatibleTrackedLayout(with: frozen) {
                return frozen
            }
            // A rebuilding menu may temporarily lose some metric rows, but retained rows and other sections
            // must still match the frozen layout.
            if fallback.hasCompatibleTrackedMetricSubset(of: frozen) {
                return frozen
            }
            return fallback
        }

        if let resolved = self.resolveModel(provider),
           fallback.hasCompatibleTrackedLayout(with: resolved)
        {
            return resolved
        }
        if let published = self.publishedManualRefreshModels[provider.instanceID],
           fallback.hasCompatibleTrackedLayout(with: published)
        {
            return published
        }
        return fallback
    }

    func subtitle(
        for provider: UsageProvider,
        fallback: MenuCardLiveSubtitle) -> MenuCardLiveSubtitle
    {
        if self.isManualRefreshInFlight(for: provider) {
            return MenuCardLiveSubtitle(text: "\(L("Refreshing"))…", style: .loading)
        }
        guard let model = self.resolveModel(provider) else { return fallback }
        return MenuCardLiveSubtitle(text: model.subtitleText, style: model.subtitleStyle)
    }
}
