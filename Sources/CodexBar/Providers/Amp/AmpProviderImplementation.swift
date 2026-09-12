import CodexBarCore
import Foundation

struct AmpProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .amp

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.ampUsageDataSource
        _ = settings.ampAPIToken
        _ = settings.ampCookieSource
        _ = settings.ampCookieHeader
    }

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode {
        context.settings.ampUsageDataSource
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let sourceBinding = context.rawValueBinding(\.ampUsageDataSource, fallback: .auto)
        let sourceOptions: [ProviderSettingsPickerOption] = [
            ProviderSettingsPickerOption(id: ProviderSourceMode.auto.rawValue, title: "Auto"),
            ProviderSettingsPickerOption(id: ProviderSourceMode.cli.rawValue, title: "Amp CLI"),
            ProviderSettingsPickerOption(id: ProviderSourceMode.api.rawValue, title: "Access token"),
            ProviderSettingsPickerOption(id: ProviderSourceMode.web.rawValue, title: "Browser cookies"),
        ]
        return [
            ProviderSettingsPickerDescriptor(
                id: "amp-usage-source",
                title: "Usage source",
                subtitle: "Auto tries the Amp CLI, access token, then browser cookies.",
                binding: sourceBinding,
                options: sourceOptions,
                isVisible: nil,
                onChange: nil),
            ProviderCookieSourceUI.picker(
                id: "amp-cookie-source",
                context: context,
                source: \.ampCookieSource,
                allowsOff: false,
                subtitles: {
                    .init(
                        auto: L("Automatic imports browser cookies."),
                        manual: L("Paste a Cookie header or cURL capture from %@.", "Amp settings"),
                        off: L("%@ cookies are disabled.", "Amp"))
                },
                isVisible: {
                    context.settings.ampUsageDataSource == .auto ||
                        context.settings.ampUsageDataSource == .web
                },
                onChange: nil),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "amp-api-token",
                title: "Access token",
                subtitle: "Stored in ~/.codexbar/config.json. You can also set AMP_API_KEY.",
                kind: .secure,
                placeholder: "sgamp_...",
                binding: context.binding(\.ampAPIToken),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "amp-open-access-tokens",
                        title: "Open Amp Access Tokens",
                        url: URL(string: "https://ampcode.com/settings")),
                ],
                isVisible: {
                    context.settings.ampUsageDataSource == .auto ||
                        context.settings.ampUsageDataSource == .api
                }),
            ProviderSettingsFieldDescriptor(
                id: "amp-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: …",
                binding: context.binding(\.ampCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "amp-open-settings",
                        title: "Open Amp Settings",
                        url: URL(string: "https://ampcode.com/settings")),
                ],
                isVisible: {
                    (context.settings.ampUsageDataSource == .auto ||
                        context.settings.ampUsageDataSource == .web) &&
                        context.settings.ampCookieSource == .manual
                }),
        ]
    }
}
