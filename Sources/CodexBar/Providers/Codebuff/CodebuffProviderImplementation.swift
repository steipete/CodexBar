import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct CodebuffProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .codebuff

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.codebuffAPIToken
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "codebuff-api-key",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. You can also provide CODEBUFF_API_KEY or let " +
                    "CodexBar read ~/.config/manicode/credentials.json (created by `codebuff login`).",
                kind: .secure,
                placeholder: "cb_...",
                binding: context.stringBinding(\.codebuffAPIToken),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "codebuff-open-dashboard",
                        title: "Open Codebuff Dashboard",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://www.codebuff.com/usage") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
