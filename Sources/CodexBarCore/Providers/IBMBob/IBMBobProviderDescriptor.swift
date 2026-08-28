import Foundation

public enum IBMBobProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: IBMBobSettingsReader.apiKeyEnvironmentKey,
        resolve: IBMBobSettingsReader.apiKey,
        tokenAccountSupport: TokenAccountSupport(
            title: "API keys",
            subtitle: "Store multiple IBM Bob API keys.",
            placeholder: "Paste API key…",
            injection: .environment(key: IBMBobSettingsReader.apiKeyEnvironmentKey),
            requiresManualCookieSource: false,
            cookieName: nil),
        missingCredentialMessage: { _ in IBMBobUsageError.missingCredentials.errorDescription })

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .ibmbob,
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .ibmbob,
                displayName: "IBM Bob",
                shortDisplayName: "IBM Bob",
                sessionLabel: "Monthly Bobcoins",
                weeklyLabel: "Monthly Bobcoins",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "Bobcoin usage from the IBM Bob API.",
                toggleTitle: "Show IBM Bob usage",
                cliName: "ibmbob",
                defaultEnabled: false,
                widgetSelectable: false,
                dashboardURL: "https://bob.ibm.com",
                subscriptionDashboardURL: "https://bob.ibm.com",
                changelogURL: "https://bob.ibm.com/docs/ide/changelog",
                statusPageURL: nil,
                statusLinkURL: "https://status.bob.ibm.com"),
            branding: ProviderBranding(
                iconStyle: .init(provider: .ibmbob),
                iconResourceName: "ProviderIcon-ibmbob",
                color: ProviderColor(red: 14 / 255, green: 97 / 255, blue: 250 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x0E61FA),
                    ProviderColor(hex: 0xA16EFB),
                    ProviderColor(hex: 0x001D6C),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "IBM Bob usage is reported in Bobcoins." }),
            fetchPlan: .apiToken(
                strategyID: "ibmbob.api",
                resolveToken: { IBMBobSettingsReader.apiKey(environment: $0) },
                missingCredentialsError: { IBMBobUsageError.missingCredentials },
                loadUsage: { apiKey, _ in
                    try await IBMBobUsageFetcher.fetchUsage(apiKey: apiKey).toUsageSnapshot()
                }),
            cli: ProviderCLIConfig(
                name: "ibmbob",
                aliases: ["ibm-bob", "bob", "bobshell"],
                versionDetector: nil))
    }
}
