import CodexBarCore
import Foundation

struct TypeSafeProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .typesafe

    @MainActor
    func tokenAccountsVisibility(context: ProviderSettingsContext, support: TokenAccountSupport) -> Bool {
        !support.requiresManualCookieSource || context.settings.typesafeCookieSource == .manual
            || !context.settings.tokenAccounts(for: .typesafe).isEmpty
    }

    @MainActor
    func applyTokenAccountCookieSource(settings: SettingsStore) {
        settings.typesafeCookieSource = .manual
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        [ProviderCookieSourceUI.picker(
            id: "typesafe-cookie-source",
            context: context,
            source: \.typesafeCookieSource,
            allowsOff: false,
            subtitles: {
                .init(
                    auto: "Automatic imports Chrome cookies from typesafe.ai.",
                    manual: "Paste a Cookie header captured from the TypeSafe billing page.",
                    off: "TypeSafe cookies are disabled.")
            },
            trailingText: {
                ProviderCookieRefreshAction.trailingText(
                    provider: .typesafe,
                    cookieSource: context.settings.typesafeCookieSource,
                    context: context)
            },
            trailingActions: [
                ProviderCookieRefreshAction.descriptor(
                    provider: .typesafe,
                    cookieSource: { context.settings.typesafeCookieSource },
                    context: context),
            ])]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [ProviderSettingsFieldDescriptor(
            id: "typesafe-cookie-header",
            title: "Cookie header",
            subtitle: "Paste the Cookie header from a billing-page request.",
            kind: .secure,
            placeholder: "Cookie: …",
            binding: context.binding(\.typesafeCookieHeader),
            actions: [.openURL(
                id: "typesafe-open-billing",
                title: "Open TypeSafe Billing",
                url: URL(string: "https://console.typesafe.ai/settings/billing"))],
            isVisible: { context.settings.typesafeCookieSource == .manual })]
    }
}
