import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct KimiProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .kimi

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "kimi-api-token",
                title: "API key",
                subtitle: "Stored in Keychain. Generate one at https://kimi-k2.ai/user-center/api-keys.",
                kind: .secure,
                placeholder: "Paste API key…",
                binding: context.stringBinding(\.kimiAPIToken),
                actions: [],
                isVisible: nil,
                onActivate: { context.settings.ensureKimiAPITokenLoaded() })
        ]
    }
}
