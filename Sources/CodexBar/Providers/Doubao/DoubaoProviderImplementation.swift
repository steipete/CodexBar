import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct DoubaoProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .doubao

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.doubaoAPIToken
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "doubao-api-token",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. Get your API key from the Volcengine "
                    + "Ark console.",
                kind: .secure,
                placeholder: "ark-...",
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
        ]
    }
}
