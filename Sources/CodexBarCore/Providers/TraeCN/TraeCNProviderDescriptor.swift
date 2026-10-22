import Foundation

public enum TraeCNProviderDescriptor {
    public static let descriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .traecn,
        displayName: "Trae CN",
        sessionLabel: "Credits",
        weeklyLabel: "Window",
        toggleTitle: "Show Trae CN usage",
        dashboardURL: "https://www.trae.cn/dashboard#usage",
        color: .init(hex: 0x4D7CFE),
        confetti: [0x4D7CFE, 0x1F2937],
        noDataMessage: "No cost history data.",
        menuBarMetrics: .init(supported: [.automatic, .primary]),
        presentation: ProviderUsagePresentation(menuBarBalanceDetailLabels: ["Remaining"]),
        aliases: ["trae-cn"],
        webSource: .init(
            settingsSection: .init(TraeCNProviderSettingsKey.self, cookieSettings: CookieProviderSettings.self),
            browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
            browserSupportExemption: { _, _, settings in settings?.traecn?.cookieSource == .manual },
            resolveValues: { $0.settings?.traecn?.cookieSource == .off ? nil : .init() },
            field: .init(
                id: "traecn-cookie-header",
                title: "Cookie header",
                subtitle: "Paste the Cookie header from a billing-page request.",
                placeholder: "Cookie: …",
                action: (id: "traecn-open-dashboard", title: "Open Dashboard", url: "https://www.trae.cn/dashboard")),
            picker: .init(
                id: "traecn-cookie-source",
                allowsOff: true,
                auto: .localized("Automatic imports browser cookies."),
                manual: .localized("Paste a Cookie header captured from %@.", argument: "api.trae.cn"),
                off: .localized("%@ cookies are disabled.", argument: "Trae CN"),
                showsRefreshAction: true),
            detailLine: "Browser cookies",
            showsVersionInSettings: false,
            loginURL: "https://www.trae.cn/dashboard"))
}

public enum TraeCNProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.traecn
    public typealias Section = CookieProviderSettings
}

extension ProviderSettingsSnapshot {
    public var traecn: CookieProviderSettings? {
        self[TraeCNProviderSettingsKey.self]
    }
}
