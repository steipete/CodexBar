import CodexBarCore
import Foundation

struct DeepgramProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .deepgram

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings[providerConfig: .deepgram, field: .apiKey]
        _ = settings[providerConfig: .deepgram, field: .workspace]
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if DeepgramSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        return !context.settings[providerConfig: .deepgram, field: .apiKey]
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "deepgram-api-key",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. Get your key from console.deepgram.com.",
                kind: .secure,
                placeholder: "dg_...",
                binding: context.providerConfigBinding(.apiKey),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "deepgram-project-id",
                title: "Project ID",
                subtitle: "Optional. Leave blank to discover and aggregate projects visible to the API key.",
                kind: .plain,
                placeholder: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
                binding: context.providerConfigBinding(.workspace),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
