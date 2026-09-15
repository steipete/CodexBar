import CodexBarCore
import Foundation

struct CommandCodeProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .commandcode

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        [
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
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
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
                isVisible: { context.settings.commandcodeCookieSource == .manual }),
        ]
    }
}
