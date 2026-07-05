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

    private let resolveModel: ModelResolver
    /// Set while an all-providers refresh is running; it freezes every provider's card.
    private var globalManualRefreshInFlight = false
    /// Providers with an individual manual refresh in flight. Concurrent entries are allowed so
    /// refreshing one provider does not stall or unfreeze another.
    private var manualRefreshProviders: Set<UsageProvider> = []
    private var frozenManualRefreshModels: [UsageProvider: UsageMenuCardView.Model] = [:]

    /// True while any manual refresh (global or per-provider) is running.
    var isManualRefreshInFlight: Bool {
        self.globalManualRefreshInFlight || !self.manualRefreshProviders.isEmpty
    }

    init(resolveModel: @escaping ModelResolver) {
        self.resolveModel = resolveModel
    }

    func beginManualRefresh(
        frozenModels: [UsageProvider: UsageMenuCardView.Model],
        provider: UsageProvider? = nil)
    {
        if let provider {
            self.frozenManualRefreshModels[provider] = frozenModels[provider]
            self.manualRefreshProviders.insert(provider)
        } else {
            self.frozenManualRefreshModels = frozenModels
            self.globalManualRefreshInFlight = true
        }
    }

    /// Balances a `beginManualRefresh` with the same `provider` argument (nil ends the global refresh).
    func endManualRefresh(for provider: UsageProvider? = nil) {
        if let provider {
            self.manualRefreshProviders.remove(provider)
            self.frozenManualRefreshModels[provider] = nil
        } else {
            self.globalManualRefreshInFlight = false
            self.frozenManualRefreshModels.removeAll(keepingCapacity: true)
        }
    }

    func resetManualRefresh() {
        self.globalManualRefreshInFlight = false
        self.manualRefreshProviders.removeAll(keepingCapacity: true)
        self.frozenManualRefreshModels.removeAll(keepingCapacity: true)
    }

    func isManualRefreshInFlight(for provider: UsageProvider) -> Bool {
        self.globalManualRefreshInFlight || self.manualRefreshProviders.contains(provider)
    }

    func model(
        for provider: UsageProvider,
        fallback: UsageMenuCardView.Model) -> UsageMenuCardView.Model
    {
        guard !self.isManualRefreshInFlight(for: provider) else {
            guard let frozen = self.frozenManualRefreshModels[provider] else {
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

        guard let resolved = self.resolveModel(provider),
              fallback.hasCompatibleTrackedLayout(with: resolved)
        else {
            return fallback
        }
        return resolved
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
