import Foundation

public enum ParallelProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .parallel,
        displayName: "Parallel",
        sessionLabel: "Balance",
        weeklyLabel: "Balance",
        toggleTitle: "Show Parallel balance",
        balanceOnly: true,
        dashboardURL: "https://platform.parallel.ai",
        color: .init(hex: 0x1D1C1A),
        confetti: [0x1D1C1A, 0x8C8C8C],
        noDataMessage: "No cost history data.",
        webSource: .init(
            settingsSection: .init(ParallelProviderSettingsKey.self, cookieSettings: CookieProviderSettings.self),
            browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
            browserSupportExemption: { _, _, settings in settings?.parallel?.cookieSource == .manual },
            resolveValues: { $0.settings?.parallel?.cookieSource == .off ? nil : .init() },
            field: .init(
                id: "parallel-cookie-header",
                title: "Cookie header",
                subtitle: "Paste the Cookie header from a billing-page request.",
                placeholder: "Cookie: …",
                action: (
                    id: "parallel-open-platform",
                    title: "Open Dashboard",
                    url: "https://platform.parallel.ai")),
            picker: .init(
                id: "parallel-cookie-source",
                allowsOff: true,
                auto: .localized("Automatic imports browser cookies."),
                manual: .localized("Paste a Cookie header captured from %@.", argument: "platform.parallel.ai"),
                off: .localized("%@ cookies are disabled.", argument: "Parallel"),
                showsRefreshAction: true),
            detailLine: "Browser cookies",
            showsVersionInSettings: false,
            loginURL: "https://platform.parallel.ai/login"))
}

public enum ParallelProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.parallel
    public typealias Section = CookieProviderSettings
}

extension ProviderSettingsSnapshot {
    public var parallel: CookieProviderSettings? {
        self[ParallelProviderSettingsKey.self]
    }
}
