import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct PoeProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .poe

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation(detailLine: ProviderPresentation.standardDetailLine)
    }

    @MainActor
    func observeSettings(_: SettingsStore) {}

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        PoeSettingsReader.apiKey(environment: context.environment) != nil
    }
}
