import Foundation

#if os(macOS)
import SweetCookieKit
#endif

public enum VeniceProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: VeniceSettingsReader.apiKeyEnvironmentKey,
        resolve: VeniceSettingsReader.apiKey,
        tokenAccountSupport: TokenAccountSupport(
            title: "API tokens",
            subtitle: "Store multiple Venice API keys.",
            placeholder: "Paste API key…",
            injection: .environment(key: VeniceSettingsReader.apiKeyEnvironmentKey),
            requiresManualCookieSource: false,
            cookieName: nil),
        // A selected API token account is the credential authority: route it
        // to the API script instead of fetching an ambient browser session
        // that would be mislabeled as that account.
        selectedAccountSourceModeResolver: { base, account, _ in account == nil ? base : .api })

    static func makeDescriptor() -> ProviderDescriptor {
        // Chrome first per repo cookie-import policy; Brave second so users
        // signed in only in Brave still resolve a web session.
        #if os(macOS)
        let browserOrder: BrowserCookieImportOrder = [.chrome, .brave]
        #else
        let browserOrder: BrowserCookieImportOrder? = nil
        #endif

        return ProviderDescriptor(
            id: .venice,
            settingsSection: .init(
                VeniceProviderSettingsKey.self,
                cookieSettings: { settings in
                    CookieProviderSettings(
                        cookieSource: settings.cookieSource,
                        manualCookieHeader: settings.manualCookieHeader)
                },
                credentialSettings: { context in
                    let settings = context.cookieSettings(for: .venice)
                    return VeniceProviderSettings(
                        cookieSource: settings.cookieSource,
                        manualCookieHeader: settings.manualCookieHeader)
                }),
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .venice,
                displayName: "Venice",
                sessionLabel: "Balance",
                weeklyLabel: "Balance",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Venice usage",
                cliName: "venice",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                debugLogUnavailableMessage: "Venice debug log not yet implemented",
                browserCookieOrder: browserOrder,
                dashboardURL: "https://venice.ai/settings/api",
                statusPageURL: nil,
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .venice),
                iconResourceName: "ProviderIcon-venice",
                color: ProviderColor(red: 0.2, green: 0.6, blue: 1.0),
                confettiPalette: [
                    ProviderColor(hex: 0x0E2942),
                    ProviderColor(hex: 0xF7F5ED),
                    ProviderColor(hex: 0x3C8FDD),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Venice per-day cost history is not available via API." }),
            presentation: ProviderUsagePresentation(
                rateWindowLabeler: { metadata, snapshot, _ in
                    ProviderRateWindowLabels(
                        primary: Self.primaryLabel(window: snapshot.primary) ?? metadata.sessionLabel,
                        secondary: metadata.weeklyLabel,
                        tertiary: metadata.opusLabel ?? "Sonnet",
                        showsTertiary: metadata.supportsOpus)
                }),
            fetchPlan: self.fetchPlan(),
            cli: ProviderCLIConfig(
                name: "venice",
                aliases: ["ven"],
                versionDetector: nil,
                // Automatic mode resolves through the API-key script without
                // touching the browser, so Linux must not reject it just
                // because an explicit web source exists. Explicit web stays
                // unsupported off macOS via the strategy itself.
                browserSupportExemption: { sourceMode, _, _ in sourceMode == .auto }))
    }

    /// Window label for the cookie-based monthly quota view.
    public static func primaryLabel(window: RateWindow?) -> String? {
        guard window?.windowMinutes == ProviderPaceCapability.monthlyWindowSentinelMinutes else {
            return nil
        }
        return "Monthly credits"
    }

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
