import CodexBarCore
import Foundation

struct SiliconFlowProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .siliconflow
    private let plugin = PluginAPIKeyProviderImplementation(spec: SiliconFlowProviderDescriptor.spec)

    @MainActor
    static func dashboardURL(
        settings: SettingsStore,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        let effectiveEnvironment = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: environment,
            provider: .siliconflow,
            config: settings.providerConfig(for: .siliconflow))
        guard let origin = SiliconFlowSettingsReader.baseURL(environment: effectiveEnvironment) else { return nil }
        let host = origin == SiliconFlowSettingsReader.chinaOrigin ? "cloud.siliconflow.cn" : "cloud.siliconflow.com"
        return URL(string: "https://\(host)")
    }

    @MainActor
    func presentation(context: ProviderPresentationContext) -> ProviderPresentation {
        self.plugin.presentation(context: context)
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        self.plugin.observeSettings(settings)
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        self.plugin.isAvailable(context: context)
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        var spec = SiliconFlowProviderDescriptor.spec
        spec.apiKeyField?.action = Self.dashboardURL(settings: context.settings).map {
            ("siliconflow-dashboard", "Open regional API keys", $0.appendingPathComponent("account/ak").absoluteString)
        }
        return PluginAPIKeyProviderImplementation(spec: spec).settingsFields(context: context)
    }
}
