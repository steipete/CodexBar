import Foundation

public enum LangdockProviderDescriptor {
    public static let descriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .langdock,
        displayName: "Langdock",
        sessionLabel: "Session",
        weeklyLabel: "Weekly",
        dashboardURL: "https://app.langdock.com/settings/account/usage",
        color: ProviderColor(hex: 0x5A4AE7),
        confetti: [0x5A4AE7, 0xB3AAFF],
        noDataMessage: "Langdock cost usage is not supported.",
        history: .unavailable,
        burnDownWidgetSelectable: false,
        webSource: .init(
            settingsSection: .init(
                LangdockProviderSettingsKey.self,
                selectedProfileBrowsers: ["edge", "chrome", "safari"]),
            field: .init(id: "langdock-session", title: "", subtitle: ""),
            detailLine: "Selected browser profile",
            showsVersionInSettings: false))
}

public enum LangdockProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.langdock
    public typealias Section = CookieProviderSettings
}
