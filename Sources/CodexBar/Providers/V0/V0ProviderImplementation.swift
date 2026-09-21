import CodexBarCore
import Foundation

struct V0ProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .v0

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings[providerConfig: .v0, field: .apiKey]
        _ = settings[providerConfig: .v0, field: .workspace]
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if V0SettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        return !context.settings[providerConfig: .v0, field: .apiKey]
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "v0-api-key",
                title: "API key",
                subtitle: "Stored in ~/.config/codexbar/config.json. Create one in v0 settings or set V0_API_KEY.",
                kind: .secure,
                placeholder: "v0_...",
                binding: context.providerConfigBinding(.apiKey),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "v0-open-api-keys",
                        title: "Open v0 API keys",
                        url: URL(string: "https://v0.app/settings/keys")),
                ],
                isVisible: nil),
            ProviderSettingsFieldDescriptor(
                id: "v0-scope",
                title: "Scope",
                subtitle: "Optional project ID or slug. Leave blank for the default v0 scope.",
                kind: .plain,
                placeholder: "project-slug",
                binding: context.providerConfigBinding(.workspace),
                actions: [],
                isVisible: nil),
        ]
    }
}
