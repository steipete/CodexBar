import CodexBarCore
import Foundation

struct HttpsLMProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .httpsLM

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "https-api" }
    }

    @MainActor
    func observeSettings(_: SettingsStore) {}

    @MainActor
    func isAvailable(context _: ProviderAvailabilityContext) -> Bool {
        true
    }

    @MainActor
    func settingsFields(context _: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        []
    }
}
