import CodexBarCore
import Foundation

struct OllamaLANProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .ollamaLAN

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "lan-api" }
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
