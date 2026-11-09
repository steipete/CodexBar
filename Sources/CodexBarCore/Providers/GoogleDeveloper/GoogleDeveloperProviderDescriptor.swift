import Foundation

public enum GoogleDeveloperProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .googledeveloper,
        displayName: "Google Developer Program",
        sessionLabel: "Cloud credits",
        weeklyLabel: "Balance",
        usesDetailBackedWindow: true,
        dashboardURL: "https://me.developers.google.com/benefits",
        color: ProviderColor(hex: 0x5B8DEF),
        confetti: [0x5B8DEF, 0xA8C7FA, 0x1F1F1F],
        noDataMessage: "Google Developer Program exposes the current monthly Cloud credit, "
            + "not local token cost history.",
        presentation: ProviderUsagePresentation(
            costPresenter: { _ in
                ProviderCostPresentation(showsGenericFallback: false, menuCardStyle: .prepaidCredits)
            },
            menuBarBalanceUsesPrepaidCost: true,
            // The monthly grant expires rather than resets, so its expiry stays a detail line.
            menuCard: ProviderMenuCardPresentation(
                showsPrimaryBalanceDescription: true,
                clearsPrimaryReset: true),
            menu: ProviderMenuDescriptorPresentation(primaryDescriptionIsDetail: { _ in true })),
        aliases: ["google-developer"],
        webSource: .init(
            settingsSection: .init(
                GoogleDeveloperProviderSettingsKey.self,
                cookieSettings: CookieProviderSettings.self),
            browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
            timeout: .fixed(60),
            browserSupportExemption: { _, _, settings in
                settings?[GoogleDeveloperProviderSettingsKey.self]?.cookieSource == .manual
            },
            field: .init(
                id: "googledeveloper-cookie",
                title: "Cookie header",
                subtitle: "Paste a me.developers.google.com Cookie header from a signed-in Google account.",
                placeholder: "Cookie: …",
                action: (
                    id: "googledeveloper-open-benefits",
                    title: "Open Dashboard",
                    url: "https://me.developers.google.com/benefits")),
            picker: .init(
                id: "googledeveloper-cookie-source",
                allowsOff: true,
                auto: .localized("Automatically imports browser session cookie."),
                manual: .localized("Paste a Cookie header from %@.", argument: "me.developers.google.com"),
                off: .localized("%@ cookies are disabled.", argument: "Google Developer Program"),
                showsRefreshAction: true),
            detailLine: "web",
            showsVersionInSettings: false,
            loginURL: "https://me.developers.google.com/"))
}

public enum GoogleDeveloperProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.googledeveloper
    public typealias Section = CookieProviderSettings
}
