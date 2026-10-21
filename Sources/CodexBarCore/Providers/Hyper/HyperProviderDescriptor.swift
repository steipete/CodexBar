public enum HyperProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.spec.makeDescriptor(credentials: Self.credentials)
    public static let spec = PluginProviderSpec(
        id: .hyper,
        displayName: "Charm Hyper",
        sessionLabel: "Balance",
        weeklyLabel: "Balance",
        balanceOnly: true,
        dashboardURL: "https://hyper.charm.land",
        color: .init(hex: 0xFF60FF),
        confetti: [0xFF60FF, 0xFFFFFF],
        noDataMessage: "Charm Hyper cost history is not available via API.",
        environmentKey: apiKeyEnvironmentKey,
        menuBarMetrics: .automaticOnly,
        presentation: ProviderUsagePresentation(
            costPresenter: { _ in ProviderCostPresentation(showsGenericFallback: false, menuCardStyle: .hidden) }),
        webSource: .init(
            settingsSection: .init(HyperProviderSettingsKey.self, cookieSettings: CookieProviderSettings.self),
            browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
            mode: .sessionOrAPI,
            browserSupportExemption: { _, _, settings in
                settings?[HyperProviderSettingsKey.self]?.cookieSource == .manual
            },
            resolveValues: { context in
                .init(
                    settings: ["SOURCE_MODE": context.sourceMode.rawValue],
                    secrets: Self.apiKey(environment: context.env)
                        .map { [apiKeyEnvironmentKey: $0] } ?? [:])
            },
            field: .init(
                id: "hyper-cookie",
                title: "Hyper cookie",
                subtitle: "Paste a Cookie header copied from a signed-in hyper.charm.land request.",
                placeholder: "Cookie: …",
                action: (id: "hyper-open-dashboard", title: "Open Charm Hyper", url: "https://hyper.charm.land")),
            picker: .init(
                id: "hyper-cookie-source",
                allowsOff: true,
                auto: .literal("Prefer a signed-in Hyper browser session, then fall back to an API key."),
                manual: .literal("Paste a Cookie header from hyper.charm.land."),
                off: .literal("Use only the configured API key."),
                showsRefreshAction: true),
            detailLine: "Session or API key",
            showsVersionInSettings: false),
        apiKeyField: .init(
            id: "hyper-api-key",
            title: "API key",
            subtitle: "Fallback when no session is available. Saved in the config file, or set HYPER_API_KEY.",
            placeholder: "Paste API key…"))

    public static let apiKeyEnvironmentKey = "HYPER_API_KEY"
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: apiKeyEnvironmentKey,
        resolve: Self.apiKey,
        tokenAccountSupport: TokenAccountSupport(
            title: "API keys",
            subtitle: "Store multiple Charm Hyper API keys.",
            placeholder: "Paste API key…",
            injection: .environment(key: apiKeyEnvironmentKey),
            requiresManualCookieSource: false,
            cookieName: nil),
        missingCredentialMessage: { _ in "Sign in to hyper.charm.land or configure a Charm Hyper API key." },
        selectedAccountSourceModeResolver: { base, account, _ in
            base == .auto && account != nil ? .api : base
        })

    public static func apiKey(environment: [String: String]) -> String? {
        SettingsValue.cleaned(environment[self.apiKeyEnvironmentKey])
    }
}

public enum HyperProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.hyper
    public typealias Section = CookieProviderSettings
}
