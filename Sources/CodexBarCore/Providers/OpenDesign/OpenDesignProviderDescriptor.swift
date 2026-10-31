import Foundation

public enum OpenDesignProviderDescriptor {
    static let diagnosticMessages = [
        "Sign in to OpenDesign, then refresh CodexBar.",
        "OpenDesign usage response format changed.",
        "OpenDesign billing access was denied.",
        "OpenDesign request failed. Try again later.",
        "OpenDesign subscription usage is unavailable for this workspace.",
    ]

    public static let descriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .opendesign,
        displayName: "OpenDesign",
        sessionLabel: "Session",
        weeklyLabel: "Weekly",
        dashboardURL: "https://open-design.ai/cloud/dashboard",
        color: .init(hex: 0x202020),
        confetti: [0x202020, 0x999999],
        progressColorStyle: .label,
        noDataMessage: "No cost history data.",
        // The website's active workspace can change between refreshes.
        history: .unavailable,
        burnDownWidgetSelectable: false,
        menuBarMetrics: .init(supported: [.automatic, .primary, .secondary]),
        aliases: ["open-design"],
        webSource: .init(
            settingsSection: .init(OpenDesignProviderSettingsKey.self, cookieSettings: CookieProviderSettings.self),
            browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
            browserSupportExemption: { _, _, settings in
                settings?[OpenDesignProviderSettingsKey.self]?.cookieSource == .manual
            },
            resolveValues: { _ in
                let messages = Dictionary(uniqueKeysWithValues: Self.diagnosticMessages.map {
                    ($0, UsageFormatter.localized($0))
                })
                let data = try? JSONEncoder().encode(messages)
                return .init(settings: ["MESSAGES": data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"])
            },
            field: .init(
                id: "opendesign-cookie-header",
                title: "Cookie header",
                subtitle: "Paste the Cookie header from a billing-page request.",
                placeholder: "Cookie: …",
                action: (
                    id: "opendesign-open-dashboard",
                    title: "Open Dashboard",
                    url: "https://open-design.ai/cloud/dashboard")),
            picker: .init(
                id: "opendesign-cookie-source",
                allowsOff: true,
                auto: .localized("Automatic imports browser cookies."),
                manual: .localized("Paste a Cookie header captured from %@.", argument: "amr-api.open-design.ai"),
                off: .localized("%@ cookies are disabled.", argument: "OpenDesign"),
                showsRefreshAction: true),
            detailLine: "Browser cookies",
            showsVersionInSettings: false,
            loginURL: "https://open-design.ai/cloud/login"))
}

public enum OpenDesignProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.opendesign
    public typealias Section = CookieProviderSettings
}
