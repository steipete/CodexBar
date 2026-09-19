import CodexBarCore
import Foundation

struct ReplicateProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .replicate

    @MainActor
    func tokenAccountsVisibility(context: ProviderSettingsContext, support: TokenAccountSupport) -> Bool {
        !support.requiresManualCookieSource || context.settings.replicateCookieSource == .manual
            || !context.settings.tokenAccounts(for: .replicate).isEmpty
    }

    @MainActor
    func applyTokenAccountCookieSource(settings: SettingsStore) {
        settings.replicateCookieSource = .manual
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        [ProviderCookieSourceUI.picker(
            id: "replicate-cookie-source",
            context: context,
            source: \.replicateCookieSource,
            allowsOff: false,
            subtitles: {
                .init(
                    auto: "Automatic imports Chrome cookies from replicate.com.",
                    manual: "Paste a Cookie header captured from the billing page.",
                    off: "Replicate cookies are disabled.")
            })]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [ProviderSettingsFieldDescriptor(
            id: "replicate-cookie-header",
            title: "Cookie header",
            subtitle: "Paste the Cookie header from a billing-page request. It must contain sessionid.",
            kind: .secure,
            placeholder: "sessionid=…; csrftoken=…",
            binding: context.binding(\.replicateCookieHeader),
            actions: [.openURL(
                id: "replicate-open-billing",
                title: "Open Replicate Billing",
                url: URL(string: "https://replicate.com/account/billing"))],
            isVisible: { context.settings.replicateCookieSource == .manual })]
    }
}
