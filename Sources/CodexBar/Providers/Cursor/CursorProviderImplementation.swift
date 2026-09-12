import CodexBarCore
import Foundation

struct CursorProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .cursor
    let supportsLoginFlow: Bool = true

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "web" }
    }

    @MainActor
    func tokenAccountsVisibility(context: ProviderSettingsContext, support: TokenAccountSupport) -> Bool {
        guard support.requiresManualCookieSource else { return true }
        if !context.settings.tokenAccounts(for: context.provider).isEmpty { return true }
        return context.settings.cursorCookieSource == .manual
    }

    @MainActor
    func applyTokenAccountCookieSource(settings: SettingsStore) {
        if settings.cursorCookieSource != .manual {
            settings.cursorCookieSource = .manual
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        [
            ProviderCookieSourceUI.picker(
                id: "cursor-cookie-source",
                context: context,
                source: \.cursorCookieSource,
                allowsOff: false,
                subtitles: {
                    .init(
                        auto: "Automatic imports browser cookies or stored sessions.",
                        manual: "Paste a Cookie header from a cursor.com request.",
                        off: "Cursor cookies are disabled.")
                },
                trailingText: {
                    ProviderCookieSourceUI.cachedTrailingText(provider: .cursor)
                }),
        ]
    }

    @MainActor
    func runLoginFlow(context: ProviderLoginContext) async -> Bool {
        await context.controller.runCursorLoginFlow()
    }

    @MainActor
    func appendUsageMenuEntries(context: ProviderMenuUsageContext, entries: inout [ProviderMenuEntry]) {
        guard context.settings.showOptionalCreditsAndExtraUsage,
              let cost = context.snapshot?.providerCost,
              cost.currencyCode != "Quota"
        else { return }
        let used = UsageFormatter.convertedCostString(
            cost.used,
            preferredCurrency: context.settings.preferredCurrencyCode,
            providerCurrency: cost.currencyCode)
        if cost.limit > 0 {
            let limitStr = UsageFormatter.convertedCostString(
                cost.limit,
                preferredCurrency: context.settings.preferredCurrencyCode,
                providerCurrency: cost.currencyCode)
            entries.append(.text(String(format: L("cursor_on_demand_with_limit"), used, limitStr), .primary))
        } else {
            entries.append(.text(String(format: L("cursor_on_demand"), used), .primary))
        }
    }
}
