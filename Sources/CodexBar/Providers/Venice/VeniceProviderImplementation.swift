import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct VeniceProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .venice

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_: SettingsStore) {}

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if VeniceSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        return !context.settings.tokenAccounts(for: .venice).isEmpty
    }

    @MainActor
    func settingsFields(context _: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        []
    }
}
