import Foundation

public enum ElevenLabsProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .elevenlabs,
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
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://elevenlabs.io/app/developers/usage",
                subscriptionDashboardURL: "https://elevenlabs.io/app/subscription",
                statusPageURL: nil,
                statusLinkURL: "https://status.elevenlabs.io"),
            branding: ProviderBranding(
                iconStyle: .elevenlabs,
                iconResourceName: "ProviderIcon-elevenlabs",
                color: ProviderColor(red: 0.92, green: 0.92, blue: 0.90)),
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
