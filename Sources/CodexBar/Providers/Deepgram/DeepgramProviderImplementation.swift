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
        _ = settings.deepgramAPIKey
        _ = settings.deepgramProjectID
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if DeepgramSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        return !context.settings.deepgramAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                binding: context.stringBinding(\.deepgramAPIKey),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "deepgram-project-id",
                title: "Project ID",
                subtitle: "Optional. Leave blank to discover and aggregate projects visible to the API key.",
                kind: .plain,
                placeholder: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
                binding: context.stringBinding(\.deepgramProjectID),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
