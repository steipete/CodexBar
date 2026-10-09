import Foundation

public enum TinyApiProviderDescriptor {
    public static let descriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .tinyapi,
        displayName: "TinyApi",
        sessionLabel: "Credits",
        weeklyLabel: "Credits",
        balanceOnly: true,
        dashboardURL: "https://tinyapi.rest/dashboard",
        color: .init(hex: 0xF97316),
        confetti: [0xF97316, 0xFBBF24],
        noDataMessage: "No cost history data.",
        history: .unavailable,
        burnDownWidgetSelectable: false,
        menuBarMetrics: .automaticOnly,
        presentation: ProviderUsagePresentation(
            menuBarBalanceDetailLabels: ["Available credits"]),
        webSource: .init(
            settingsSection: .init(TinyApiProviderSettingsKey.self, cookieSettings: CookieProviderSettings.self),
            browserCookieOrder: BrowserCookieImportSupport.chromeOnly(
                reason: "TinyApi imports only Chrome to avoid unrelated browser prompts."),
            browserSupportExemption: { _, _, settings in
                settings?[TinyApiProviderSettingsKey.self]?.cookieSource == .manual
            },
            resolveValues: { context in
                context.settings?[TinyApiProviderSettingsKey.self]?.cookieSource == .off ? nil : .init()
            },
            field: .init(
                id: "tinyapi-cookie",
                title: "Cookie header",
                subtitle: "Stored in the CodexBar config file.",
                placeholder: "Cookie: …"),
            picker: .init(
                id: "tinyapi-cookie-source",
                allowsOff: true,
                auto: .localized("Automatic imports browser cookies."),
                manual: .localized("Paste a Cookie header captured from %@.", argument: "tinyapi.rest"),
                off: .localized("%@ cookies are disabled.", argument: "TinyApi"),
                showsRefreshAction: true),
            detailLine: "Browser session",
            showsVersionInSettings: false))
}

public enum TinyApiProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.tinyapi
    public typealias Section = CookieProviderSettings
}
