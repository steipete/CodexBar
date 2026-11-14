import CodexBarCore
import Foundation
import SwiftUI

struct SiliconFlowProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .siliconflow
    private let plugin = PluginCookieProviderImplementation(spec: SiliconFlowProviderDescriptor.spec)
    private let apiKey = PluginAPIKeyProviderImplementation(spec: SiliconFlowProviderDescriptor.spec)

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
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { $0.store.sourceLabel(for: $0.provider) }
    }

    @MainActor
    func defaultSourceLabel(context: ProviderSourceLabelContext) -> String? {
        context.settings.providerConfig(for: self.id)?.source?.rawValue
    }

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode {
        context.settings.providerConfig(for: self.id)?.source ?? .auto
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.providerConfig(for: self.id)?.source
        self.plugin.observeSettings(settings)
        _ = settings[providerConfig: self.id, field: .endpoint]
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        self.plugin.settingsSnapshot(context: context)
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        guard context.settings.providerConfig(for: self.id)?.source == .web else {
            return self.apiKey.isAvailable(context: context)
        }
        return Self.dashboardURL(settings: context.settings, environment: context.environment)?.host
            == "cloud.siliconflow.cn"
            && context.settings.resolvedCookieSource(provider: self.id, fallback: .auto) != .off
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let source = ProviderSettingsPickerDescriptor(
            id: "siliconflow-usage-source",
            title: "Usage source",
            subtitle: "",
            binding: Binding(
                get: { context.settings.providerConfig(for: self.id)?.source?.rawValue ?? "auto" },
                set: { raw in
                    let mode = ProviderSourceMode(rawValue: raw) ?? .auto
                    guard mode != (context.settings.providerConfig(for: self.id)?.source ?? .auto) else { return }
                    context.store.clearProviderState(self.id)
                    context.settings.updateProviderConfig(provider: self.id) { $0.source = mode }
                }),
            options: [
                .init(id: "auto", title: "Auto"),
                .init(id: "api", title: "API key"),
                .init(id: "web", title: "Web"),
            ],
            isVisible: nil,
            onChange: nil)
        return [source] + (context.settings.providerConfig(for: self.id)?.source == .web
            ? self.plugin.settingsPickers(context: context) : [])
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        var spec = SiliconFlowProviderDescriptor.spec
        spec.apiKeyField?.action = Self.dashboardURL(settings: context.settings).map {
            ("siliconflow-dashboard", "Open regional API keys", $0.appendingPathComponent("account/ak").absoluteString)
        }
        return context.settings.providerConfig(for: self.id)?.source == .web
            ? PluginCookieProviderImplementation(spec: spec).settingsFields(context: context)
            : PluginAPIKeyProviderImplementation(spec: spec).settingsFields(context: context)
    }
}
