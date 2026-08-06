import Foundation

public enum ElevenLabsProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: ElevenLabsSettingsReader.apiKeyEnvironmentKey,
        resolve: ElevenLabsSettingsReader.apiKey,
        tokenAccountSupport: TokenAccountSupport(
            title: "API keys",
            subtitle: "Store multiple ElevenLabs API keys.",
            placeholder: "Paste API key…",
            injection: .environment(key: ElevenLabsSettingsReader.apiKeyEnvironmentKey),
            requiresManualCookieSource: false,
            cookieName: nil),
        missingCredentialMessage: { _ in ElevenLabsUsageError.missingCredentials.errorDescription })

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .elevenlabs,
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .elevenlabs,
                displayName: "ElevenLabs",
                sessionLabel: "Credits",
                weeklyLabel: "Voices",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show ElevenLabs usage",
                cliName: "elevenlabs",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                sharePlanLabels: [
                    "free": "Free", "starter": "Starter", "creator": "Creator", "pro": "Pro",
                    "scale": "Scale", "business": "Business", "growing business": "Business",
                    "enterprise": "Enterprise",
                ],
                browserCookieOrder: nil,
                dashboardURL: "https://elevenlabs.io/app/developers/usage",
                subscriptionDashboardURL: "https://elevenlabs.io/app/subscription",
                statusPageURL: nil,
                statusLinkURL: "https://status.elevenlabs.io"),
            branding: ProviderBranding(
                iconStyle: .init(provider: .elevenlabs),
                iconResourceName: "ProviderIcon-elevenlabs",
                color: ProviderColor(red: 0.92, green: 0.92, blue: 0.90),
                confettiPalette: [
                    ProviderColor(hex: 0x000000),
                    ProviderColor(hex: 0x808080),
                    ProviderColor(hex: 0xFDFCFC),
                ],
                widgetColor: ProviderColor(red: 235 / 255, green: 235 / 255, blue: 230 / 255),
                progressColorStyle: .label),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "ElevenLabs cost history is not available via API yet." }),
            fetchPlan: .apiToken(
                strategyID: "elevenlabs.api",
                resolveToken: { ProviderTokenResolver.elevenLabsToken(environment: $0) },
                missingCredentialsError: { ElevenLabsUsageError.missingCredentials },
                loadUsage: { apiKey, context in
                    try await ElevenLabsUsageFetcher.fetchUsage(
                        apiKey: apiKey,
                        environment: context.env).toUsageSnapshot()
                }),
            cli: ProviderCLIConfig(
                name: "elevenlabs",
                aliases: ["11labs", "eleven"],
                versionDetector: nil))
    }
}
