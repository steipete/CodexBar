import AppKit
import CodexBarCore
import Foundation

struct AiAndProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .aiand

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.aiAndAPIKey
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if AiAndSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        return !context.settings.aiAndAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "aiand-api-key",
                title: "API key",
                subtitle: "Stored in CodexBar's config file. Create a key in the ai& console (shown once).",
                kind: .secure,
                placeholder: "sk-…",
                binding: context.stringBinding(\.aiAndAPIKey),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "aiand-open-console",
                        title: "Open ai& Console",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://console.aiand.com") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
