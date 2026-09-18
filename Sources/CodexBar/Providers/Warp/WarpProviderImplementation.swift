import CodexBarCore
import Foundation

struct WarpProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .warp

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings[providerConfig: .warp, field: .apiKey]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "warp-api-token",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. In Warp, open Settings > Platform > API Keys, "
                    + "then create one.",
                kind: .secure,
                placeholder: "wk-...",
                binding: context.providerConfigBinding(.apiKey),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "warp-open-api-keys",
                        title: "Open Warp API Key Guide",
                        url: URL(string: "https://docs.warp.dev/reference/cli/api-keys")),
                ],
                isVisible: nil),
        ]
    }
}
