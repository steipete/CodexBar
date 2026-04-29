import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct DeepSeekProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .deepseek

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.deepSeekAPIToken
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if DeepSeekSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        context.settings.ensureDeepSeekAPITokenLoaded()
        return !context.settings.deepSeekAPIToken
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "deepseek-api-key",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. Generate one at platform.deepseek.com/api_keys.",
                kind: .secure,
                placeholder: "sk-...",
                binding: context.stringBinding(\.deepSeekAPIToken),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "deepseek-open-api-keys",
                        title: "Open API Keys",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://platform.deepseek.com/api_keys") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil,
                onActivate: { context.settings.ensureDeepSeekAPITokenLoaded() }),
        ]
    }
}
