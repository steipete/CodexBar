import CodexBarCore
import Foundation

struct JevProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .jev

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        [
            ProviderCookieSourceUI.picker(
                id: "jev-cookie-source",
                context: context,
                source: \.jevCookieSource,
                allowsOff: false,
                subtitles: {
                    .init(
                        auto: L("Automatically import the TypeSafe console session."),
                        manual: L("Paste a Cookie header from %@.", "console.typesafe.ai"),
                        off: L("%@ cookies are disabled.", "Jev"))
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "jev-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: …",
                binding: context.binding(\.jevCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "jev-open-console",
                        title: "Open TypeSafe Console",
                        url: URL(string: "https://console.typesafe.ai/usage")!),
                ],
                isVisible: { context.settings.jevCookieSource == .manual }),
        ]
    }
}
