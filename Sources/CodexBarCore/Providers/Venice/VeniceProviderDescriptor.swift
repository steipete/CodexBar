import Foundation

public enum VeniceProviderDescriptor {
    public static let descriptor = Self.spec.makeDescriptor(
        credentials: Self.credentials,
        fetchPlan: Self.fetchPlan())
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: VeniceSettingsReader.apiKeyEnvironmentKey,
        resolve: VeniceSettingsReader.apiKey,
        tokenAccountSupport: TokenAccountSupport(
            title: "API tokens",
            subtitle: "Store multiple Venice API keys.",
            placeholder: "Paste API key…",
            injection: .environment(key: VeniceSettingsReader.apiKeyEnvironmentKey),
            requiresManualCookieSource: false,
            cookieName: nil,
            passiveSourceModes: [.web]),
        // A selected API token account is the credential authority: route it
        // to the API script instead of fetching an ambient browser session
        // that would be mislabeled as that account.
        selectedAccountSourceModeResolver: { base, account, _ in account == nil ? base : .api })

    public static let spec = PluginProviderSpec(
        id: .venice,
        displayName: "Venice",
        sessionLabel: "Balance",
        weeklyLabel: "Balance",
        debugLogUnavailableMessage: "Venice debug log not yet implemented",
        dashboardURL: "https://venice.ai/settings/api",
        color: ProviderColor(hex: 0x3C8FDD),
        confetti: [0x0E2942, 0xF7F5ED, 0x3C8FDD],
        widgetColor: ProviderColor(hex: 0x3399FF),
        noDataMessage: "Venice per-day cost history is not available via API.",
        aliases: ["ven"],
        webSource: .init(
            settingsSection: .init(VeniceProviderSettingsKey.self, cookieSettings: VeniceProviderSettings.self),
            browserCookieOrder: BrowserCookieImportSupport.chromeOnly(
                reason: "Preserve Chrome web sessions without unrelated Keychain prompts"),
            mode: .sessionOrAPI,
            // Auto uses the API key; only explicit web mode requires browser support.
            browserSupportExemption: { sourceMode, _, _ in sourceMode == .auto },
            field: .init(id: "venice-cookie", title: "", subtitle: "", placeholder: "Cookie: …")))

    private static func fetchPlan() -> ProviderFetchPlan {
        ProviderFetchPlan(
            sourceModes: [.auto, .api, .web],
            pipeline: ProviderFetchPipeline(resolveStrategies: { context in
                let script = ScriptFetchStrategy(
                    id: "venice.js",
                    provider: .venice,
                    bundledPlugin: "venice",
                    secretKey: VeniceSettingsReader.apiKeyEnvironmentKey,
                    sourceLabel: "api",
                    resolveSecret: { environment in
                        self.credentials.resolveToken(environment: environment)?.token
                    },
                    isEnabled: { _ in true })
                // Explicit web source uses only the cookie strategy so a
                // missing session surfaces the sign-in error instead of
                // silently falling back to the API key.
                guard context.sourceMode == .web else { return [script] }
                return [VeniceWebFetchStrategy(timeout: context.webTimeout)]
            }))
    }
}
