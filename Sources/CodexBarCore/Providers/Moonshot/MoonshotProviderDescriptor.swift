import Foundation

public enum MoonshotProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .moonshot,
            metadata: ProviderMetadata(
                id: .moonshot,
                displayName: "Moonshot / Kimi Open Platform",
                sessionLabel: "Balance",
                weeklyLabel: "Balance",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Moonshot / Kimi open-platform balance",
                cliName: "moonshot",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                // International console by default; China uses platform.kimi.com via region-aware UI actions.
                dashboardURL: "https://platform.moonshot.ai/console/account",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .kimi,
                iconResourceName: "ProviderIcon-kimi",
                color: ProviderColor(red: 32 / 255, green: 93 / 255, blue: 235 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x121212),
                    ProviderColor(hex: 0x305140),
                    ProviderColor(hex: 0x9F9F9F),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Moonshot / Kimi open-platform cost summary is not available." }),
            fetchPlan: .apiToken(
                strategyID: "moonshot.api",
                resolveToken: { ProviderTokenResolver.moonshotToken(environment: $0) },
                missingCredentialsError: { MoonshotUsageError.missingCredentials },
                loadUsage: { apiKey, context in
                    let region =
                        context.settings?.moonshot?.region ?? MoonshotSettingsReader.region(environment: context.env)
                    return try await MoonshotUsageFetcher.fetchUsage(
                        apiKey: apiKey,
                        region: region).toUsageSnapshot()
                }),
            cli: ProviderCLIConfig(
                name: "moonshot",
                // Common aliases when users look for “Kimi China / open platform”.
                aliases: ["kimi-open", "kimi-cn", "moonshot-cn"],
                versionDetector: nil))
    }
}
