import AppKit
import CodexBarCore
import Foundation

struct MiMoProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .mimo
    let supportsLoginFlow: Bool = true

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "web" }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        [
            ProviderCookieSourceUI.picker(
                id: "mimo-cookie-source",
                context: context,
                source: \.miMoCookieSource,
                allowsOff: false,
                subtitles: {
                    .init(
                        auto: "Automatic imports browser cookies from Xiaomi MiMo.",
                        manual: "Paste a Cookie header from platform.xiaomimimo.com.",
                        off: "Xiaomi MiMo cookies are disabled.")
                },
                trailingText: {
                    ProviderCookieSourceUI.cachedTrailingText(provider: .mimo)
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "mimo-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: ...",
                binding: context.binding(\.miMoCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "mimo-open-balance",
                        title: "Open MiMo Balance",
                        url: URL(string: "https://platform.xiaomimimo.com/#/console/balance")),
                ],
                isVisible: { context.settings.miMoCookieSource == .manual }),
        ]
    }

    @MainActor
    func runLoginFlow(context _: ProviderLoginContext) async -> Bool {
        let loginURL = "https://platform.xiaomimimo.com/api/v1/genLoginUrl?currentPath=%2F%23%2Fconsole%2Fbalance"
        guard let url = URL(string: loginURL) else {
            return false
        }
        NSWorkspace.shared.open(url)
        return false
    }
}
