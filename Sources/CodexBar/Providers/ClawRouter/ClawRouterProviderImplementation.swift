import CodexBarCore
import Foundation

struct ClawRouterProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .clawrouter

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings[providerConfig: .clawrouter, field: .apiKey]
        _ = settings[providerConfig: .clawrouter, field: .endpoint]
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        ProviderTokenResolver.token(for: .clawrouter, environment: context.environment) != nil
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "clawrouter-api-key",
                title: "API key",
                subtitle: "Stored in the CodexBar config file. Reads monthly budget and routed usage from /v1/usage.",
                kind: .secure,
                placeholder: "ClawRouter key…",
                binding: context.providerConfigBinding(.apiKey),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "clawrouter-base-url",
                title: "Base URL",
                subtitle: "Optional. Defaults to the hosted ClawRouter service.",
                kind: .plain,
                placeholder: ClawRouterSettingsReader.defaultBaseURL.absoluteString,
                binding: context.providerConfigBinding(.endpoint),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
