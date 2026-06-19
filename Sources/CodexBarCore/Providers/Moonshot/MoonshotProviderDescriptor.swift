import Foundation

public enum MoonshotProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .moonshot,
            metadata: ProviderMetadata(
                id: .moonshot,
                displayName: "Moonshot / Kimi API",
                sessionLabel: "Balance",
                weeklyLabel: "Balance",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Moonshot / Kimi API balance",
                cliName: "moonshot",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://platform.moonshot.ai/console/account",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .kimi,
                iconResourceName: "ProviderIcon-kimi",
                color: ProviderColor(red: 32 / 255, green: 93 / 255, blue: 235 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Moonshot / Kimi API cost summary is not available." }),
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
                aliases: [],
                versionDetector: nil))
    }
}
