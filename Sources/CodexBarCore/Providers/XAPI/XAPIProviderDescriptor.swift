import Foundation

public enum XAPIProviderDescriptor {
    public static let descriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .xapi,
        displayName: "X API",
        sessionLabel: "Balance",
        weeklyLabel: "Balance",
        balanceOnly: true,
        dashboardURL: "https://console.x.com",
        color: ProviderColor(hex: 0x71767B),
        confetti: [0x71767B, 0xD6D9DB],
        noDataMessage: "X API cost history is not available.",
        history: .unavailable,
        burnDownWidgetSelectable: false,
        menuBarMetrics: .automaticOnly,
        presentation: ProviderUsagePresentation(
            costPresenter: { _ in
                ProviderCostPresentation(showsGenericFallback: false, menuCardStyle: .hidden)
            }),
        webSource: .init(
            settingsSection: .init(XAPIProviderSettingsKey.self, cookieSettings: CookieProviderSettings.self),
            browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
            timeout: .fixed(30),
            browserSupportExemption: { _, _, settings in
                settings?[XAPIProviderSettingsKey.self]?.cookieSource == .manual
            },
            field: .init(
                id: "xapi-cookie",
                title: "Cookie header",
                subtitle: "Paste a console.x.com Cookie header containing auth_token and ct0.",
                placeholder: "Cookie: …",
                action: (id: "xapi-open-console", title: "Open X Developer Console", url: "https://console.x.com")),
            picker: .init(
                id: "xapi-cookie-source",
                allowsOff: true,
                auto: .literal("Import a signed-in X developer console session from your browser."),
                manual: .literal("Paste console cookies from the same session."),
                off: .literal("X API cookies are disabled."),
                showsRefreshAction: true),
            detailLine: "Browser session",
            showsVersionInSettings: false))
}

public enum XAPIProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.xapi
    public typealias Section = CookieProviderSettings
}
