import CodexBarCore
import Foundation

struct VeniceProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .venice

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if VeniceSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        return !context.settings.tokenAccounts(for: .venice).isEmpty
    }
}
