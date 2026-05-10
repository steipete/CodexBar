import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct OpenAIAPIProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .openai

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.openAIAPIKey
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if OpenAIAPISettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        return !context.settings.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "openai-api-key",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. You can also provide OPENAI_API_KEY.",
                kind: .secure,
                placeholder: "sk-...",
                binding: context.stringBinding(\.openAIAPIKey),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "openai-open-billing",
                        title: "Open billing",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(
                                string: "https://platform.openai.com/settings/organization/billing/overview")
                            {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
