import CodexBarCore
import Foundation

struct GrokBotProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .grokbot
    let supportsLoginFlow: Bool = true

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "web" }
    }

    @MainActor
    func tokenAccountsVisibility(context: ProviderSettingsContext, support: TokenAccountSupport) -> Bool {
        guard support.requiresManualCookieSource else { return true }
        if !context.settings.tokenAccounts(for: context.provider).isEmpty { return true }
        return context.settings.grokbotCookieSource == .manual
    }

    @MainActor
    func applyTokenAccountCookieSource(settings: SettingsStore) {
        if settings.grokbotCookieSource != .manual {
            settings.grokbotCookieSource = .manual
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        [
            ProviderCookieSourceUI.picker(
                id: "grokbot-cookie-source",
                context: context,
                source: \.grokbotCookieSource,
                allowsOff: false,
                subtitles: {
                    .init(
                        auto: L("Automatic imports browser cookies or stored Cursor sessions."),
                        manual: L("Paste a Cookie header from %@.", "a cursor.com request"),
                        off: L("%@ cookies are disabled.", "Grok Bot"))
                },
                trailingText: {
                    ProviderCookieSourceUI.cachedTrailingText(provider: .grokbot)
                }),
        ]
    }

    @MainActor
    func runLoginFlow(context: ProviderLoginContext) async -> Bool {
        await context.controller.runGrokBotLoginFlow()
    }
}
