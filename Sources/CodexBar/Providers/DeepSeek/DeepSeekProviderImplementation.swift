import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct DeepSeekProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .deepseek

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_: SettingsStore) {}

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if DeepSeekSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        return !context.settings.tokenAccounts(for: .deepseek).isEmpty
    }

    @MainActor
    func settingsFields(context _: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        []
    }
}
