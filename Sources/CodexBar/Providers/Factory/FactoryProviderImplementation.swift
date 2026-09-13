import CodexBarCore
import Foundation

struct FactoryProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .factory
    let supportsLoginFlow: Bool = true

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.factoryUsageDataSource
        _ = settings.factoryAPIKey
        _ = settings.factoryCookieSource
        _ = settings.factoryCookieHeader
    }

    @MainActor
    func defaultSourceLabel(context: ProviderSourceLabelContext) -> String? {
        context.settings.factoryUsageDataSource.rawValue
    }

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode {
        switch context.settings.factoryUsageDataSource {
        case .api: .api
        case .web: .web
        case .auto, .cli, .oauth: .auto
        }
    }

    @MainActor
    func tokenAccountsVisibility(context: ProviderSettingsContext, support: TokenAccountSupport) -> Bool {
        guard support.requiresManualCookieSource else { return true }
        if !context.settings.tokenAccounts(for: context.provider).isEmpty { return true }
        return context.settings.factoryCookieSource == .manual
    }

    @MainActor
    func applyTokenAccountCookieSource(settings: SettingsStore) {
        if settings.factoryCookieSource != .manual {
            settings.factoryCookieSource = .manual
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let usageBinding = context.rawValueBinding(\.factoryUsageDataSource, fallback: .auto)
        let usageOptions = [
            ProviderSettingsPickerOption(id: ProviderSourceMode.auto.rawValue, title: "Auto"),
            ProviderSettingsPickerOption(id: ProviderSourceMode.api.rawValue, title: "API key"),
            ProviderSettingsPickerOption(id: ProviderSourceMode.web.rawValue, title: "Browser cookies"),
        ]

        return [
            ProviderSettingsPickerDescriptor(
                id: "factory-usage-source",
                title: "Usage source",
                subtitle: "Auto tries a Factory API key first, then falls back to cookies/WorkOS on "
                    + "auth or recoverable API failures.",
                binding: usageBinding,
                options: usageOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    guard context.settings.factoryUsageDataSource == .auto else { return nil }
                    let label = context.store.sourceLabel(for: .factory)
                    return label == "auto" ? nil : label
                }),
            ProviderCookieSourceUI.picker(
                id: "factory-cookie-source",
                context: context,
                source: \.factoryCookieSource,
                allowsOff: false,
                subtitles: {
                    .init(
                        auto: L("Automatic imports browser cookies and WorkOS tokens."),
                        manual: L("Paste a Cookie or Authorization header from %@.", "app.factory.ai"),
                        off: L("%@ cookies are disabled.", "Factory"))
                },
                trailingText: {
                    ProviderCookieSourceUI.cachedTrailingText(provider: .factory)
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "factory-api-key",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. You can also provide FACTORY_API_KEY or "
                    + "~/.factory/.env.",
                kind: .secure,
                placeholder: "fk-...",
                binding: context.binding(\.factoryAPIKey),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "factory-open-api-keys",
                        title: "Open API keys",
                        url: URL(string: "https://app.factory.ai/settings/api-keys")),
                ],
                isVisible: nil),
        ]
    }

    @MainActor
    func runLoginFlow(context: ProviderLoginContext) async -> Bool {
        await context.controller.runFactoryLoginFlow()
        return true
    }

    @MainActor
    func loginMenuAction(context _: ProviderMenuLoginContext)
        -> (label: String, action: MenuDescriptor.MenuAction)?
    {
        ("Open Droid in Browser...", .loginToProvider(url: "https://app.factory.ai"))
    }

    @MainActor
    func appendUsageMenuEntries(context: ProviderMenuUsageContext, entries: inout [ProviderMenuEntry]) {
        guard context.settings.showOptionalCreditsAndExtraUsage,
              let cost = context.snapshot?.providerCost,
              cost.period == "Extra usage balance"
        else { return }

        let balance = UsageFormatter.convertedCostString(
            cost.used,
            preferredCurrency: context.settings.preferredCurrencyCode,
            providerCurrency: cost.currencyCode)
        entries.append(.text(L("Extra usage balance: %@", balance), .primary))
    }
}
