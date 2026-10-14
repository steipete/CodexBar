import CodexBarCore
import Foundation

struct CommandCodeProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .commandcode

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.commandcodeUsageDataSource
        _ = settings.commandcodeAPIKey
        _ = settings.commandcodeCookieSource
        _ = settings.commandcodeCookieHeader
    }

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode {
        context.settings.commandcodeUsageDataSource
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        [
            ProviderSettingsPickerDescriptor(
                id: "commandcode-usage-source",
                title: "Usage source",
                subtitle: "Auto uses an API key when configured, otherwise browser cookies.",
                binding: context.rawValueBinding(\.commandcodeUsageDataSource, fallback: .auto),
                options: [
                    ProviderSettingsPickerOption(id: ProviderSourceMode.auto.rawValue, title: "Auto"),
                    ProviderSettingsPickerOption(id: ProviderSourceMode.api.rawValue, title: "API key"),
                    ProviderSettingsPickerOption(id: ProviderSourceMode.web.rawValue, title: "Browser cookies"),
                ],
                isVisible: nil,
                onChange: nil),
            ProviderCookieSourceUI.picker(
                id: "commandcode-cookie-source",
                context: context,
                source: \.commandcodeCookieSource,
                allowsOff: false,
                subtitles: {
                    .init(
                        auto: L("Automatic imports browser cookies."),
                        manual: L("Paste a Cookie header or cURL capture from %@.", "Command Code"),
                        off: L("%@ cookies are disabled.", "Command Code"))
                },
                isVisible: { context.settings.commandcodeUsageDataSource != .api }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "commandcode-api-key",
                title: "API key",
                subtitle: "Stored in the CodexBar config file. You can also set COMMAND_CODE_API_KEY.",
                kind: .secure,
                placeholder: "API key",
                binding: context.binding(\.commandcodeAPIKey),
                actions: [],
                isVisible: { context.settings.commandcodeUsageDataSource != .web }),
            ProviderSettingsFieldDescriptor(
                id: "commandcode-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: …",
                binding: context.binding(\.commandcodeCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "commandcode-open-settings",
                        title: "Open Command Code Settings",
                        url: URL(string: "https://commandcode.ai/studio")),
                ],
                isVisible: {
                    context.settings.commandcodeUsageDataSource != .api &&
                        context.settings.commandcodeCookieSource == .manual
                }),
        ]
    }
}
