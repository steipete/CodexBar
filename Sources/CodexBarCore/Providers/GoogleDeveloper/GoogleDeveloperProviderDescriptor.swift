import Foundation

public enum GoogleDeveloperProviderDescriptor {
    static let messages = [
        "%@ cookies are disabled.",
        "%@ of %@ left",
        "Browser session",
        "Expires %@",
        "Google Developer Program is rate limiting requests. Try again later.",
        "Google Developer Program request failed. Try refreshing later.",
        "Google Developer Program returned an unrecognized response. Update CodexBar and try again.",
        "Google session expired or invalid.",
        "No Cloud credit found. Check your Google Developer Program benefits.",
        "No Google Developer Program session cookies found. Sign in at me.developers.google.com/benefits "
            + "or paste a Cookie header.",
        "Not applied",
        "Supported browsers: %@. Use Manual for other browsers.",
    ]

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
            resolveValues: { _ in
                let messages = Dictionary(uniqueKeysWithValues: Self.messages.map {
                    ($0, UsageFormatter.localized($0))
                })
                let data = try? JSONEncoder().encode(messages)
                return .init(settings: ["MESSAGES": data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"])
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
