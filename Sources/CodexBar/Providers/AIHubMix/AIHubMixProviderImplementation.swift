import CodexBarCore
import Foundation

struct AIHubMixProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .aihubmix

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings[providerConfig: .aihubmix, field: .apiKey]
        _ = settings.tokenAccountsData(for: .aihubmix)
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if AIHubMixSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        if !context.settings[providerConfig: .aihubmix, field: .apiKey]
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return true
        }
        return !context.settings.tokenAccounts(for: .aihubmix).isEmpty
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "aihubmix-manage-key",
                title: "Manage key",
                subtitle: "System Access Token from AIHubMix Settings. Inference API keys (sk-) are not accepted.",
                kind: .secure,
                placeholder: "Paste Manage Key…",
                binding: context.providerConfigBinding(.apiKey),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
