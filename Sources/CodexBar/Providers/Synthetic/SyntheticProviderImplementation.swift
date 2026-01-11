import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct SyntheticProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .synthetic

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "synthetic-api-key",
                title: "API key",
                subtitle: "Stored in Keychain. Paste the key from the Synthetic dashboard.",
                kind: .secure,
                placeholder: "Paste key…",
                binding: context.stringBinding(\.syntheticAPIToken),
                actions: [],
                isVisible: nil,
                onActivate: { context.settings.ensureSyntheticAPITokenLoaded() }),
        ]
    }
}
