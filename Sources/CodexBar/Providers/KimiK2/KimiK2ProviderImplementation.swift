import AppKit
import CodexBarCore
import Foundation

struct KimiK2ProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .kimik2

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.kimiK2APIToken
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "kimi-k2-api-token",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. For the official Kimi API, use Moonshot / Kimi API.",
                kind: .secure,
                placeholder: "Paste API key…",
                binding: context.stringBinding(\.kimiK2APIToken),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "kimi-k2-open-api-keys",
                        title: "Open legacy provider docs",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://github.com/steipete/CodexBar/blob/main/docs/kimi-k2.md") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil,
                onActivate: { context.settings.ensureKimiK2APITokenLoaded() }),
        ]
    }
}
