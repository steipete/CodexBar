import AppKit
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
                subtitle: "Use a Volcengine access key ID with the secret field for Coding Plan usage, "
                    + "or leave the secret blank to use an Ark API key.",
                kind: .secure,
                placeholder: "ark-... or AKLT...",
                binding: context.stringBinding(\.doubaoAPIToken),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "doubao-open-dashboard",
                        title: "Open Volcengine Ark Console",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://console.volcengine.com/ark/") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "doubao-secret-access-key",
                title: "Secret access key",
                subtitle: "Volcengine secret access key for the signed Coding Plan usage API.",
                kind: .secure,
                placeholder: "",
                binding: context.stringBinding(\.doubaoSecretAccessKey),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "doubao-region",
                title: "Region",
                subtitle: "Volcengine Ark region. Defaults to cn-beijing.",
                kind: .plain,
                placeholder: DoubaoSettingsReader.defaultRegion,
                binding: context.stringBinding(\.doubaoRegion),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
