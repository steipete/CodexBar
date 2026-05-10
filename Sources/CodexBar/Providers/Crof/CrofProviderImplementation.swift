import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct CrofProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .crof

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.crofAPIToken
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if CrofSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        return !context.settings.crofAPIToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "crof-api-key",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. You can also provide CROF_API_KEY.",
                kind: .secure,
                placeholder: "crof_...",
                binding: context.stringBinding(\.crofAPIToken),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "crof-open-dashboard",
                        title: "Open Crof dashboard",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://crof.ai/dashboard") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
