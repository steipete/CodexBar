import AppKit
import CodexBarCore
import Foundation

struct HuggingFaceProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .huggingface

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings[providerConfig: .huggingface, field: .apiKey]
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if HuggingFaceSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        if !context.settings[providerConfig: .huggingface, field: .apiKey].isEmpty {
            return true
        }
        return !context.settings.tokenAccounts(for: .huggingface).isEmpty
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "huggingface-api-token",
                title: "Access token",
                subtitle: "Create a token at huggingface.co/settings/tokens. Classic read tokens work; "
                    + "fine-grained tokens need the Billing read permission.",
                kind: .secure,
                placeholder: "Paste access token…",
                binding: context.providerConfigBinding(.apiKey),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "huggingface-open-tokens",
                        title: "Open Hugging Face",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            NSWorkspace.shared.open(HuggingFaceURLs.tokens)
                        }),
                ],
                isVisible: nil),
        ]
    }
}

enum HuggingFaceURLs {
    static let tokens = URL(string: "https://huggingface.co/settings/tokens")!
}
