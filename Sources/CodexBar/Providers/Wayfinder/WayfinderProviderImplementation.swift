import CodexBarCore
import Foundation

struct WayfinderProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .wayfinder

    @MainActor
    static func dashboardURL(
        settings: SettingsStore,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        let effectiveEnvironment = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: environment,
            provider: .wayfinder,
            config: settings.providerConfig(for: .wayfinder))
        return WayfinderSettingsReader.dashboardURL(environment: effectiveEnvironment)
    }

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.wayfinderGatewayURL
    }

    @MainActor
    func isAvailable(context _: ProviderAvailabilityContext) -> Bool {
        // The gateway's read-only API needs no credentials; enabling the provider is the opt-in.
        true
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "wayfinder-gateway-url",
                title: "Gateway URL",
                subtitle: "Local Wayfinder gateway. Read-only polling of health, routing split, and " +
                    "savings — prompts are never read or sent.",
                kind: .plain,
                placeholder: WayfinderSettingsReader.defaultBaseURL.absoluteString,
                binding: context.stringBinding(\.wayfinderGatewayURL),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
