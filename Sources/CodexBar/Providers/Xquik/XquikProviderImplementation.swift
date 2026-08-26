import AppKit
import CodexBarCore
import Foundation

struct XquikProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .xquik

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings[providerConfig: .xquik, field: .apiKey]
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if XquikSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        return !context.settings[providerConfig: .xquik, field: .apiKey]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "xquik-api-key",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. You can also provide XQUIK_API_KEY.",
                kind: .secure,
                placeholder: "xq_...",
                binding: context.providerConfigBinding(.apiKey),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "xquik-open-dashboard",
                        title: "Open Xquik",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://xquik.com") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
