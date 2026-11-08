import CodexBarCore
import Foundation

struct SiliconFlowProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .siliconflow
    private let plugin = PluginCookieProviderImplementation(spec: SiliconFlowProviderDescriptor.spec)
    private let apiKey = PluginAPIKeyProviderImplementation(spec: SiliconFlowProviderDescriptor.spec)

    @MainActor
    static func dashboardURL(
        settings: SettingsStore,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        guard let origin = Self.origin(settings: settings, environment: environment) else { return nil }
        let host = origin == SiliconFlowSettingsReader.chinaOrigin ? "cloud.siliconflow.cn" : "cloud.siliconflow.com"
        return URL(string: "https://\(host)")
    }

    @MainActor
    private static func origin(settings: SettingsStore, environment: [String: String]) -> URL? {
        let effectiveEnvironment = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: environment,
            provider: .siliconflow,
            config: settings.providerConfig(for: .siliconflow))
        return SiliconFlowSettingsReader.baseURL(environment: effectiveEnvironment)
    }

    @MainActor
    func presentation(context: ProviderPresentationContext) -> ProviderPresentation {
        self.apiKey.presentation(context: context)
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        self.plugin.observeSettings(settings)
        _ = settings[providerConfig: self.id, field: .endpoint]
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        self.plugin.settingsSnapshot(context: context)
    }

    /// China accounts refresh from a browser session, so they no longer need an API key.
    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if self.apiKey.isAvailable(context: context) { return true }
        return Self.origin(settings: context.settings, environment: context.environment)
            == SiliconFlowSettingsReader.chinaOrigin
            && context.settings.resolvedCookieSource(provider: self.id, fallback: .auto) != .off
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        self.plugin.settingsPickers(context: context)
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        var spec = SiliconFlowProviderDescriptor.spec
        spec.apiKeyField?.action = Self.dashboardURL(settings: context.settings).map {
            ("siliconflow-dashboard", "Open regional API keys", $0.appendingPathComponent("account/ak").absoluteString)
        }
        return PluginCookieProviderImplementation(spec: spec).settingsFields(context: context)
    }
}
