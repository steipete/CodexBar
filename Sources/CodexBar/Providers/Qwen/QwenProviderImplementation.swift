import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct QwenProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .qwen

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.qwenAPIToken
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "qwen-api-token",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. Get your API key from the Alibaba Cloud "
                    + "Bailian console (DashScope).",
                kind: .secure,
                placeholder: "sk-...",
                binding: context.stringBinding(\.qwenAPIToken),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "qwen-open-dashboard",
                        title: "Open Bailian Console",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://bailian.console.aliyun.com/") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
