import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct MiniMaxProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .minimax

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "minimax-api-token",
                title: "API token",
                subtitle: "Stored in Keychain. Paste your MiniMax API key.",
                kind: .secure,
                placeholder: "Paste API token…",
                binding: context.stringBinding(\.minimaxAPIToken),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "minimax-open-dashboard",
                        title: "Open Coding Plan",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(
                                string: "https://platform.minimax.io/user-center/payment/coding-plan?cycle_type=3")
                            {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil,
                onActivate: { context.settings.ensureMiniMaxAPITokenLoaded() }),
        ]
    }
}
