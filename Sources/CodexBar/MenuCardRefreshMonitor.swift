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
    private var frozenManualRefreshModels: [UsageProvider: UsageMenuCardView.Model] = [:]

    init(resolveModel: @escaping ModelResolver) {
        self.resolveModel = resolveModel
    }

    func beginManualRefresh(frozenModels: [UsageProvider: UsageMenuCardView.Model]) {
        self.frozenManualRefreshModels = frozenModels
        self.isManualRefreshInFlight = true
    }

    func endManualRefresh() {
        self.isManualRefreshInFlight = false
        self.frozenManualRefreshModels.removeAll(keepingCapacity: true)
    }

    func model(
        for provider: UsageProvider,
        fallback: UsageMenuCardView.Model) -> UsageMenuCardView.Model
    {
        guard !self.isManualRefreshInFlight else {
            guard let frozen = self.frozenManualRefreshModels[provider],
                  fallback.hasCompatibleTrackedLayout(with: frozen)
            else {
                return fallback
            }
            return frozen
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
        if self.isManualRefreshInFlight {
            return MenuCardLiveSubtitle(text: "\(L("Refreshing"))…", style: .loading)
        }
        guard let model = self.resolveModel(provider) else { return fallback }
        return MenuCardLiveSubtitle(text: model.subtitleText, style: model.subtitleStyle)
    }
}
