import CodexBarCore
import Foundation

struct CrofProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .crof

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings[providerConfig: .crof, field: .apiKey]
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if CrofSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        return !context.settings[providerConfig: .crof, field: .apiKey].trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "crof-api-key",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. You can also provide CROF_API_KEY.",
                kind: .secure,
                placeholder: "crof_...",
                binding: context.providerConfigBinding(.apiKey),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "crof-open-dashboard",
                        title: "Open Crof dashboard",
                        url: URL(string: "https://crof.ai/dashboard")),
                ],
                isVisible: nil),
        ]
    }
}
