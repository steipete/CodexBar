import Foundation

public enum LithosAIProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .lithosai,
        displayName: "LithosAI",
        sessionLabel: "Balance",
        weeklyLabel: "Spend",
        balanceOnly: true,
        dashboardURL: "https://console.lithosai.cloud",
        color: ProviderColor(hex: 0x6B7280),
        confetti: [0x6B7280, 0xD1D5DB],
        noDataMessage: "LithosAI exposes prepaid balance and console spend, not local token cost history.",
        menuBarMetrics: .automaticOnly,
        presentation: ProviderUsagePresentation(
            costPresenter: { _ in
                ProviderCostPresentation(showsGenericFallback: false, menuCardStyle: .prepaidCredits)
            }),
        webSource: .init(
            settingsSection: .init(LithosAIProviderSettingsKey.self, cookieSettings: CookieProviderSettings.self),
            browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
            timeout: .fixed(60),
            browserSupportExemption: { _, _, settings in
                settings?[LithosAIProviderSettingsKey.self]?.cookieSource == .manual
            },
            field: .init(
                id: "lithosai-cookie",
                title: "Cookie header",
                subtitle: "Paste a console.lithosai.cloud Cookie header with "
                    + "__Host-console_session and __Host-console_csrf.",
                placeholder: "Cookie: …",
                action: (
                    id: "lithosai-open-console", title: "Open LithosAI Console",
                    url: "https://console.lithosai.cloud")),
            picker: .init(
                id: "lithosai-cookie-source",
                allowsOff: true,
                auto: .literal("Import a signed-in LithosAI console session from your browser."),
                manual: .literal("Paste both console cookies from the same session."),
                off: .literal("LithosAI cookies are disabled."),
                showsRefreshAction: true),
            detailLine: "Browser session",
            showsVersionInSettings: false))
}

public enum LithosAIProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.lithosai
    public typealias Section = CookieProviderSettings
}
