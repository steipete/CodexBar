import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct WaferProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .wafer

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_: SettingsStore) {}

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if WaferSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        return !context.settings.tokenAccounts(for: .wafer).isEmpty
    }

    @MainActor
    func settingsFields(context _: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        []
    }
}
