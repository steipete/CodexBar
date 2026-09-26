import Foundation

public enum ClineProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter(
        supportsAPIKeyOverride: true,
        environmentProjections: [.apiKey(ClineSettingsReader.apiKeyEnvironmentKey)],
        tokenResolver: { kind, environment, authFileURL in
            guard kind == .primary else { return nil }
            if let token = ClineSettingsReader.apiKey(environment: environment) {
                return ProviderTokenResolution(token: token, source: .environment)
            }
            let fileToken: String? = if let authFileURL {
                ClineSettingsReader.authToken(authFileURL: authFileURL)
            } else {
                ClineSettingsReader.authToken(environment: environment)
            }
            guard let fileToken else { return nil }
            return ProviderTokenResolution(token: fileToken, source: .authFile)
        },
        authDetector: { environment, _ in
            ClineSettingsReader.resolvedToken(environment: environment) == nil ? [] : ["api"]
        },
        missingCredentialMessage: { _ in
            "Cline credentials not found. Paste an API key from app.cline.bot Settings → API Keys, " +
                "or run `cline auth` to sign in with your browser."
        })

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .cline,
            menuBarMetrics: .automaticOnly,
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .cline,
                displayName: "Cline",
                shortDisplayName: "Cline",
                sessionLabel: "Balance",
                weeklyLabel: "Balance",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Cline usage",
                cliName: "cline",
                defaultEnabled: false,
                widgetSelectable: false,
                balanceOnly: true,
                dashboardURL: "https://app.cline.bot/dashboard",
                subscriptionDashboardURL: "https://app.cline.bot/dashboard/subscription?personal=true",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .cline),
                iconResourceName: "ProviderIcon-cline",
                color: ProviderColor(hex: 0x1A1A1A),
                confettiPalette: [
                    ProviderColor(hex: 0x1A1A1A),
                    ProviderColor(hex: 0x61A3FA),
                    ProviderColor(hex: 0xFFFFFF),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Cline cost history is not available via the balance API." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                    [ScriptFetchStrategy(
                        id: "cline.js",
                        provider: .cline,
                        bundledPlugin: "cline",
                        secretKey: ClineSettingsReader.apiKeyEnvironmentKey,
                        sourceLabel: "api",
                        resolveValues: { context in
                            guard let token = ClineSettingsReader.apiKey(environment: context.env)
                                ?? ClineSettingsReader.authToken(environment: context.env)
                            else { return nil }
                            let source = ClineSettingsReader.apiKey(environment: context.env) != nil
                                ? "api"
                                : "oauth"
                            return ScriptFetchStrategy.Values(
                                settings: [ClineSettingsReader.authSourceSettingKey: source],
                                secrets: [ClineSettingsReader.apiKeyEnvironmentKey: token])
                        },
                        isEnabled: { _ in true })]
                })),
            cli: ProviderCLIConfig(
                name: "cline",
                aliases: ["cline-usage-billing"],
                versionDetector: nil))
    }
}
