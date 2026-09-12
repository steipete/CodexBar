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
        _ = settings.huggingFaceAPIToken
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if HuggingFaceSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        if context.settings.hasHuggingFaceCredentials {
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
                binding: context.stringBinding(\.huggingFaceAPIToken),
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
                isVisible: nil,
                onActivate: nil),
        ]
    }
}

enum HuggingFaceURLs {
    static let tokens = URL(string: "https://huggingface.co/settings/tokens")!
}
