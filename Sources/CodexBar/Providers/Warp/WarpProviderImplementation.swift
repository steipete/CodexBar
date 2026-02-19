import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct WarpProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .warp

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.warpAPIToken
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
                binding: context.stringBinding(\.warpAPIToken),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "warp-open-api-keys",
                        title: "Open Warp API Key Guide",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://docs.warp.dev/reference/cli/api-keys") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
