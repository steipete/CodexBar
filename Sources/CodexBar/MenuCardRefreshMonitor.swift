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

    init(resolveModel: @escaping ModelResolver) {
        self.resolveModel = resolveModel
    }

    func model(
        for provider: UsageProvider,
        fallback: UsageMenuCardView.Model) -> UsageMenuCardView.Model
    {
        guard !self.isManualRefreshInFlight,
              let resolved = self.resolveModel(provider),
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
