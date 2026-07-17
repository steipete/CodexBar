import Foundation

public enum ClinePassProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .clinepass,
            metadata: ProviderMetadata(
                id: .clinepass,
                displayName: "ClinePass",
                sessionLabel: "5-hour",
                weeklyLabel: "Weekly",
                opusLabel: "Monthly",
                supportsOpus: true,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show ClinePass usage",
                cliName: "clinepass",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://app.cline.bot/dashboard/subscription?personal=true",
                statusPageURL: nil,
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .clinepass,
                iconResourceName: "ProviderIcon-clinepass",
                color: ProviderColor(red: 0.38, green: 0.64, blue: 0.98),
                confettiPalette: [
                    ProviderColor(hex: 0x61A3FA),
                    ProviderColor(hex: 0x111111),
                    ProviderColor(hex: 0xFFFFFF),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "ClinePass cost history is not available via the usage-limits API." }),
            fetchPlan: .apiToken(
                strategyID: "clinepass.api",
                resolveToken: { ProviderTokenResolver.clinePassToken(environment: $0) },
                missingCredentialsError: { ClinePassUsageError.missingCredentials },
                loadUsage: { apiKey, _ in
                    try await ClinePassUsageFetcher.fetchUsage(apiKey: apiKey).toUsageSnapshot()
                }),
            cli: ProviderCLIConfig(
                name: "clinepass",
                aliases: [],
                versionDetector: nil))
    }
}
