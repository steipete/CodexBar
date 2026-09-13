import CodexBarCore
import Foundation

struct AbacusProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .abacus

    @MainActor
    func tokenAccountsVisibility(context: ProviderSettingsContext, support: TokenAccountSupport) -> Bool {
        guard support.requiresManualCookieSource else { return true }
        if !context.settings.tokenAccounts(for: context.provider).isEmpty { return true }
        return context.settings.abacusCookieSource == .manual
    }

    @MainActor
    func applyTokenAccountCookieSource(settings: SettingsStore) {
        if settings.abacusCookieSource != .manual {
            settings.abacusCookieSource = .manual
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        [
            ProviderCookieSourceUI.picker(
                id: "abacus-cookie-source",
                context: context,
                source: \.abacusCookieSource,
                allowsOff: false,
                subtitles: {
                    .init(
                        auto: L("Automatic imports browser cookies."),
                        manual: L("Paste a Cookie header or cURL capture from %@.", "the Abacus AI dashboard"),
                        off: L("%@ cookies are disabled.", "Abacus AI"))
                },
                trailingText: {
                    ProviderCookieSourceUI.cachedTrailingText(provider: .abacus)
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "abacus-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: \u{2026}\n\nor paste a cURL capture from the Abacus AI dashboard",
                binding: context.binding(\.abacusCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "abacus-open-dashboard",
                        title: "Open Dashboard",
                        url: URL(string: "https://apps.abacus.ai/chatllm/admin/compute-points-usage")),
                ],
                isVisible: { context.settings.abacusCookieSource == .manual }),
        ]
    }
}
