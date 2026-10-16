import CodexBarCore
import Foundation

struct FutureAGIProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .futureagi

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        PluginAPIKeyProviderImplementation(spec: FutureAGIProviderDescriptor.spec).settingsFields(context: context) + [
            ProviderSettingsFieldDescriptor(
                id: "futureagi-secret-key",
                title: "Secret key",
                subtitle: "Required with the API key. Saved in the local config file. Or set FI_SECRET_KEY.",
                kind: .secure,
                placeholder: "Paste secret key…",
                binding: context.providerConfigSecretBinding(key: "FI_SECRET_KEY", logField: "secretKey"),
                actions: [],
                isVisible: nil),
        ]
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.providerConfig(for: self.id)
    }
}
