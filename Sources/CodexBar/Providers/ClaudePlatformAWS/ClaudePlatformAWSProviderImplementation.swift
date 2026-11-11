import CodexBarCore
import Foundation

struct ClaudePlatformAWSProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .claudeplatformaws

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        // Access key ID, then its secret, then the regions field supplied by the shared spec.
        var fields = PluginAPIKeyProviderImplementation(spec: ClaudePlatformAWSProviderDescriptor.spec)
            .settingsFields(context: context)
        fields.insert(
            ProviderSettingsFieldDescriptor(
                id: "claudeplatformaws-secret-access-key",
                title: "Secret access key",
                subtitle: "Required with the access key ID. Saved in the local config file. "
                    + "Or set ANTHROPIC_AWS_SECRET_ACCESS_KEY.",
                kind: .secure,
                placeholder: "Paste secret key…",
                binding: context.providerConfigSecretBinding(
                    key: ClaudePlatformAWSProviderDescriptor.secretAccessKeyEnvironmentKey,
                    logField: "secretAccessKey"),
                actions: [],
                isVisible: nil),
            at: min(1, fields.count))
        return fields
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.providerConfig(for: self.id)
    }
}
