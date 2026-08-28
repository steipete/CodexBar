import AppKit
import CodexBarCore
import Foundation

struct ZenMuxProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .zenmux

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings[providerConfig: .zenmux, field: .apiKey]
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if ZenMuxSettingsReader.managementAPIKey(environment: context.environment) != nil {
            return true
        }
        return !context.settings[providerConfig: .zenmux, field: .apiKey]
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "zenmux-management-api-key",
                title: "Management API key",
                subtitle: "Stored in ~/.codexbar/config.json. Standard ZenMux inference API keys are not supported.",
                kind: .secure,
                placeholder: "ZenMux management key…",
                binding: context.providerConfigBinding(.apiKey),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "zenmux-open-management",
                        title: "Open ZenMux Management",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://zenmux.ai/platform/management") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
