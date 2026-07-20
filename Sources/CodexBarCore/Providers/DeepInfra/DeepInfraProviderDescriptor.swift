import Foundation

public enum DeepInfraProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .deepinfra,
            metadata: ProviderMetadata(
                id: .deepinfra,
                displayName: "DeepInfra",
                sessionLabel: "Balance",
                weeklyLabel: "Balance",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show DeepInfra usage",
                cliName: "deepinfra",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://deepinfra.com/dash",
                statusPageURL: nil,
                statusLinkURL: "https://status.deepinfra.com"),
            branding: ProviderBranding(
                iconStyle: .deepinfra,
                iconResourceName: "ProviderIcon-deepinfra",
                color: ProviderColor(red: 42 / 255, green: 50 / 255, blue: 117 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x2A3275),
                    ProviderColor(hex: 0x747FDE),
                    ProviderColor(hex: 0xFFFFFF),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "DeepInfra per-request cost history is not available in CodexBar." }),
            fetchPlan: .apiToken(
                strategyID: "deepinfra.api",
                resolveToken: { ProviderTokenResolver.deepInfraToken(environment: $0) },
                missingCredentialsError: { DeepInfraUsageError.missingCredentials },
                loadUsage: { apiKey, _ in
                    try await DeepInfraUsageFetcher.fetchUsage(apiKey: apiKey).toUsageSnapshot()
                }),
            cli: ProviderCLIConfig(
                name: "deepinfra",
                aliases: ["deep-infra", "di"],
                versionDetector: nil))
    }
}
