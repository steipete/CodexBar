import CodexBarCore
import Foundation

struct GroqProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .groq

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "metrics" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.groqAPIKey
    }

    // No `isAvailable` override: when Groq is enabled, the fetch pipeline resolves
    // the console browser session (primary) or the optional API key (Enterprise
    // Prometheus fallback). Matches the MiMo cookie provider.

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "groq-api-key",
                title: "API key",
                subtitle: "Usage & spend come from your console.groq.com browser session automatically. " +
                    "An API key is optional and only adds Enterprise Prometheus metrics.",
                kind: .secure,
                placeholder: "gsk_...",
                binding: context.stringBinding(\.groqAPIKey),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
