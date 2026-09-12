import CodexBarCore
import Foundation

struct KimiProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .kimi

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { context in
            context.store.sourceLabel(for: context.provider)
        }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.kimiUsageDataSource
        _ = settings.kimiAPIKey
        _ = settings.kimiCookieSource
        _ = settings.kimiManualCookieHeader
    }

    @MainActor
    func defaultSourceLabel(context: ProviderSourceLabelContext) -> String? {
        context.settings.kimiUsageDataSource.rawValue
    }

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode {
        switch context.settings.kimiUsageDataSource {
        case .api: .api
        case .web: .web
        case .auto, .cli, .oauth: .auto
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let usageBinding = context.rawValueBinding(\.kimiUsageDataSource, fallback: .auto)
        let usageOptions = [
            ProviderSettingsPickerOption(id: ProviderSourceMode.auto.rawValue, title: "Auto"),
            ProviderSettingsPickerOption(id: ProviderSourceMode.api.rawValue, title: "API key"),
            ProviderSettingsPickerOption(id: ProviderSourceMode.web.rawValue, title: "Browser cookies"),
        ]

        return [
            ProviderSettingsPickerDescriptor(
                id: "kimi-usage-source",
                title: "Usage source",
                subtitle: "Kimi Code subscription usage from api.kimi.com. Auto tries your configured API key, " +
                    "then a signed-in Kimi Code CLI credential, then web cookies. China Open Platform balance " +
                    "is a separate provider.",
                binding: usageBinding,
                options: usageOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    guard context.settings.kimiUsageDataSource == .auto else { return nil }
                    let label = context.store.sourceLabel(for: .kimi)
                    return label == "auto" ? nil : label
                }),
            ProviderCookieSourceUI.picker(
                id: "kimi-cookie-source",
                context: context,
                source: \.kimiCookieSource,
                allowsOff: true,
                subtitles: {
                    .init(
                        auto: "Automatic imports browser cookies.",
                        manual: "Paste a cookie header or the kimi-auth token value.",
                        off: "Kimi cookies are disabled.")
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "kimi-api-key",
                title: "Kimi Code API key",
                subtitle: "Kimi Code key from www.kimi.com/code. For China Open Platform balance, use " +
                    "Moonshot / Kimi Open Platform.",
                kind: .secure,
                placeholder: "Paste Kimi Code API key...",
                binding: context.binding(\.kimiAPIKey),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "kimi-open-api-docs",
                        title: "Open API docs",
                        url: URL(string: "https://www.kimi.com/code/docs/en/")),
                ],
                isVisible: nil),
            ProviderSettingsFieldDescriptor(
                id: "kimi-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: \u{2026}\n\nor paste the kimi-auth token value",
                binding: context.binding(\.kimiManualCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "kimi-open-console",
                        title: "Open Console",
                        url: URL(string: "https://www.kimi.com/code/console")),
                ],
                isVisible: { context.settings.kimiCookieSource == .manual }),
        ]
    }
}
