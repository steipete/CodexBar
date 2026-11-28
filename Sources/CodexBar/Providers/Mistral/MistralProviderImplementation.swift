import CodexBarCore
import Foundation

struct MistralProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .mistral

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { $0.store.sourceLabel(for: self.id) }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.mistralCookieSource
        _ = settings.mistralCookieHeader
        _ = settings.mistralAPIKey
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
                allowsOff: true,
                subtitles: {
                    .init(
                        auto: L("Automatic imports browser cookies from admin.mistral.ai."),
                        manual: L("Paste a Cookie header captured from %@.", "the billing page"),
                        off: L("%@ cookies are disabled.", "Mistral"))
                },
                trailingText: {
                    ProviderCookieRefreshAction.trailingText(
                        provider: .mistral,
                        cookieSource: context.settings.mistralCookieSource,
                        context: context)
                },
                trailingActions: [
                    ProviderCookieRefreshAction.descriptor(
                        provider: .mistral,
                        cookieSource: { context.settings.mistralCookieSource },
                        browserOnly: true,
                        context: context),
                ]),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "mistral-api-key",
                title: "API key",
                subtitle: "Optional. Reads included API and Vibe allowances without browser cookies.",
                kind: .secure,
                placeholder: "API key",
                binding: context.binding(\.mistralAPIKey),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "mistral-open-api-keys",
                        title: "Open API keys",
                        url: URL(string: "https://console.mistral.ai/api-keys")),
                ],
                isVisible: nil),
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
