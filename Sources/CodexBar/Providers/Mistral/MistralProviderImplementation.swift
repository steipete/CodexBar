import CodexBarCore
import Foundation

struct MistralProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .mistral

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "web" }
    }

    @MainActor
    func tokenAccountsVisibility(context: ProviderSettingsContext, support: TokenAccountSupport) -> Bool {
        guard support.requiresManualCookieSource else { return true }
        if !context.settings.tokenAccounts(for: context.provider).isEmpty { return true }
        return context.settings.mistralCookieSource == .manual
    }

    @MainActor
    func applyTokenAccountCookieSource(settings: SettingsStore) {
        if settings.mistralCookieSource != .manual {
            settings.mistralCookieSource = .manual
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        [
            ProviderCookieSourceUI.picker(
                id: "mistral-cookie-source",
                context: context,
                source: \.mistralCookieSource,
                allowsOff: false,
                subtitles: {
                    .init(
                        auto: "Automatic imports browser cookies from admin.mistral.ai.",
                        manual: "Paste a Cookie header captured from the billing page.",
                        off: "Mistral cookies are disabled.")
                },
                trailingText: {
                    ProviderCookieSourceUI.cachedTrailingText(provider: .mistral)
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "mistral-cookie-header",
                title: "Cookie header",
                subtitle: "Paste the Cookie header from a request to admin.mistral.ai. "
                    + "Must contain an ory_session_* cookie.",
                kind: .secure,
                placeholder: "ory_session_…=…; csrftoken=…",
                binding: context.binding(\.mistralCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "mistral-open-console",
                        title: "Open Mistral Admin",
                        url: URL(string: "https://admin.mistral.ai/organization/usage")),
                ],
                isVisible: { context.settings.mistralCookieSource == .manual }),
        ]
    }
}
