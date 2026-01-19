import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct KimiK2ProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .kimik2

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "kimi-k2-api-token",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. Generate one at kimi-k2.ai.",
                kind: .secure,
                placeholder: "Paste API key…",
                binding: context.stringBinding(\.kimiK2APIToken),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "kimi-k2-open-api-keys",
                        title: "Open API Keys",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://kimi-k2.ai/user-center/api-keys") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil,
                onActivate: { context.settings.ensureKimiK2APITokenLoaded() }),
        ]
    }
}
