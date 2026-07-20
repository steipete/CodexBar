import CodexBarCore
import Foundation

struct DeepInfraProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .deepinfra

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_: SettingsStore) {}

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if DeepInfraSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        return !context.settings.tokenAccounts(for: .deepinfra).isEmpty
    }

    @MainActor
    func settingsFields(context _: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        []
    }
}
