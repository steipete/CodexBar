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
        _ = settings.clawRouterAPIKey
        _ = settings.clawRouterBaseURL
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        ProviderTokenResolver.clawRouterToken(environment: context.environment) != nil
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
                binding: context.stringBinding(\.clawRouterAPIKey),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "clawrouter-base-url",
                title: "Base URL",
                subtitle: "Optional. Defaults to the hosted ClawRouter service.",
                kind: .plain,
                placeholder: ClawRouterSettingsReader.defaultBaseURL.absoluteString,
                binding: context.stringBinding(\.clawRouterBaseURL),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
