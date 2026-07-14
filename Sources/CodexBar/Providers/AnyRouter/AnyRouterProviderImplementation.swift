import CodexBarCore
import Foundation

struct AnyRouterProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .anyrouter

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.tokenAccountsData(for: .anyrouter)
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if AnyRouterSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        return !context.settings.tokenAccounts(for: .anyrouter).isEmpty
    }

    @MainActor
    func settingsFields(context _: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        []
    }
}
