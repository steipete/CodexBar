import CodexBarCore
import Foundation

struct T3ChatProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .t3chat

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        [
            ProviderCookieSourceUI.picker(
                id: "t3chat-cookie-source",
                context: context,
                source: \.t3ChatCookieSource,
                allowsOff: false,
                subtitles: {
                    .init(
                        auto: "Automatically imports browser cookies.",
                        manual: "Paste a Cookie header or cURL capture from T3 Chat settings.",
                        off: "Paste a Cookie header or cURL capture from T3 Chat settings.")
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "t3chat-cookie",
                title: "T3 Chat cookie",
                subtitle: "Paste a Cookie header or full cURL capture from T3 Chat settings.",
                kind: .secure,
                placeholder: "Cookie: ...",
                binding: context.binding(\.t3ChatCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "t3chat-open-settings",
                        title: "Open T3 Chat Settings",
                        url: URL(string: "https://t3.chat/settings/customization")),
                ],
                isVisible: { context.settings.t3ChatCookieSource == .manual }),
        ]
    }
}
