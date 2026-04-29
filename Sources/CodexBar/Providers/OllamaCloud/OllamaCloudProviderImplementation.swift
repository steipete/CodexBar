import CodexBarCore
import Foundation

struct OllamaCloudProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .ollamaCloud

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "cloud-api" }
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
