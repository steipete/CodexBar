import CodexBarCore
import Foundation

struct DoubaoProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .doubao

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.doubaoAPIToken
        _ = settings.doubaoSecretAccessKey
        _ = settings.doubaoRegion
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "doubao-api-token",
                title: "API key / Access key ID",
                subtitle: "Without configured API credentials, install and authenticate 'arkcli' for "
                    + "Coding/Agent Plan usage. Existing API credentials remain authoritative.",
                kind: .secure,
                placeholder: "ark-... or AKLT...",
                binding: context.binding(\.doubaoAPIToken),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "doubao-open-dashboard",
                        title: "Open Volcengine Ark Console",
                        url: URL(string: "https://console.volcengine.com/ark/")),
                ],
                isVisible: nil),
            ProviderSettingsFieldDescriptor(
                id: "doubao-secret-access-key",
                title: "Secret access key",
                subtitle: "Optional. Only needed if arkcli is unavailable and you use Volcengine AK/SK signing.",
                kind: .secure,
                placeholder: "",
                binding: context.binding(\.doubaoSecretAccessKey),
                actions: [],
                isVisible: nil),
            ProviderSettingsFieldDescriptor(
                id: "doubao-region",
                title: "Region",
                subtitle: "Volcengine Ark region. Defaults to cn-beijing.",
                kind: .plain,
                placeholder: DoubaoSettingsReader.defaultRegion,
                binding: context.binding(\.doubaoRegion),
                actions: [],
                isVisible: nil),
        ]
    }
}
