import CodexBarCore
import Foundation

struct AugmentProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .augment

    @MainActor
    func tokenAccountsVisibility(context: ProviderSettingsContext, support: TokenAccountSupport) -> Bool {
        guard support.requiresManualCookieSource else { return true }
        if !context.settings.tokenAccounts(for: context.provider).isEmpty { return true }
        return context.settings.augmentCookieSource == .manual
    }

    @MainActor
    func applyTokenAccountCookieSource(settings: SettingsStore) {
        if settings.augmentCookieSource != .manual {
            settings.augmentCookieSource = .manual
        }
    }

    func makeRuntime() -> (any ProviderRuntime)? {
        AugmentProviderRuntime()
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        [
            ProviderCookieSourceUI.picker(
                id: "augment-cookie-source",
                context: context,
                source: \.augmentCookieSource,
                allowsOff: false,
                subtitles: {
                    .init(
                        auto: L("Automatic imports browser cookies."),
                        manual: L("Paste a Cookie header or cURL capture from %@.", "the Augment dashboard"),
                        off: L("%@ cookies are disabled.", "Augment"))
                },
                trailingText: {
                    ProviderCookieSourceUI.cachedTrailingText(provider: .augment)
                }),
        ]
    }

    @MainActor
    func appendActionMenuEntries(context: ProviderMenuActionContext, entries: inout [ProviderMenuEntry]) {
        entries.append(.action(L("Refresh Session"), .refreshAugmentSession))

        if let error = context.store.error(for: .augment) {
            if error.contains("session has expired") ||
                error.contains("No Augment session cookie found")
            {
                entries.append(.action(
                    L("Open Augment (Log Out & Back In)"),
                    .loginToProvider(url: "https://app.augmentcode.com")))
            }
        }
    }
}
