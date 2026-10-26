public enum RaycastProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .raycast,
        displayName: "Raycast",
        sessionLabel: "Credits",
        weeklyLabel: "Plan",
        usesDetailBackedWindow: true,
        dashboardURL: "https://www.raycast.com/settings",
        color: .init(hex: 0xFF6363),
        confetti: [0xFF6363, 0xFF8C8C, 0x1A1A1A],
        noDataMessage: "Raycast AI credits are a monthly allowance, not a cost history.",
        menuBarMetrics: ProviderMenuBarMetricCapabilities(supported: [.automatic, .primary]),
        presentation: ProviderUsagePresentation(
            menuCard: ProviderMenuCardPresentation(
                showsPrimaryBalanceDescription: true,
                hidesPrimaryResetWithoutDate: true),
            menu: ProviderMenuDescriptorPresentation(
                primaryDescriptionIsDetail: { _ in true }),
            planRow: ProviderPlanRowPresentation(label: "Plan")),
        webSource: .init(
            settingsSection: .init(RaycastProviderSettingsKey.self, cookieSettings: CookieProviderSettings.self),
            browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
            timeout: .web(minimum: 30, maximum: .infinity, padding: 0, nonFinite: 30),
            browserSupportExemption: { _, _, settings in
                settings?.raycast?.cookieSource == .manual
            },
            resolveValues: { context in
                guard context.settings?.raycast?.cookieSource != .off else { return nil }
                return .init(settings: ["webTimeoutSeconds": String(context.webTimeout)])
            },
            field: .init(
                id: "raycast-cookie-header",
                title: "Cookie header",
                subtitle: "Paste the Cookie header from a www.raycast.com/settings request. It must contain __raycast_session.",
                placeholder: "__raycast_session=…; csrf_token=…",
                action: (
                    id: "raycast-open-settings",
                    title: "Open Raycast Account",
                    url: "https://www.raycast.com/settings")),
            picker: .init(
                id: "raycast-cookie-source",
                allowsOff: true,
                auto: .localized("Automatic imports browser cookies from www.raycast.com."),
                manual: .localized("Paste a Cookie header captured from %@.", argument: "the account settings page"),
                off: .localized("%@ cookies are disabled.", argument: "Raycast"),
                showsRefreshAction: true),
            detailLine: "web",
            showsVersionInSettings: false))
}
