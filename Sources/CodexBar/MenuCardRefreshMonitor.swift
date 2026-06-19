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
    var isManualRefreshInFlight = false
    private var manualRefreshProvider: UsageProvider?
    private var frozenManualRefreshModels: [UsageProvider: UsageMenuCardView.Model] = [:]

    init(resolveModel: @escaping ModelResolver) {
        self.resolveModel = resolveModel
    }

    func beginManualRefresh(
        frozenModels: [UsageProvider: UsageMenuCardView.Model],
        provider: UsageProvider? = nil)
    {
        self.frozenManualRefreshModels = frozenModels
        self.manualRefreshProvider = provider
        self.isManualRefreshInFlight = true
    }

    func endManualRefresh() {
        self.isManualRefreshInFlight = false
        self.manualRefreshProvider = nil
        self.frozenManualRefreshModels.removeAll(keepingCapacity: true)
    }

    func isManualRefreshInFlight(for provider: UsageProvider) -> Bool {
        self.isManualRefreshInFlight && (self.manualRefreshProvider == nil || self.manualRefreshProvider == provider)
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
