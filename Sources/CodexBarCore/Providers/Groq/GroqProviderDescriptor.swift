import Foundation

public enum GroqProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .groq,
            metadata: ProviderMetadata(
                id: .groq,
                displayName: "Groq",
                sessionLabel: "Requests",
                weeklyLabel: "Tokens",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Groq usage",
                cliName: "groqcloud",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://console.groq.com/dashboard/metrics",
                statusPageURL: nil,
                statusLinkURL: "https://status.groq.com"),
            branding: ProviderBranding(
                iconStyle: .groq,
                iconResourceName: "ProviderIcon-groq",
                color: ProviderColor(red: 245 / 255, green: 104 / 255, blue: 68 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Groq cost history is not available via the metrics API." }),
            fetchPlan: .apiToken(
                strategyID: "groq.api",
                sourceLabel: "metrics",
                resolveToken: { ProviderTokenResolver.groqToken(environment: $0) },
                missingCredentialsError: { GroqUsageError.missingCredentials },
                loadUsage: { apiKey, context in
                    try await GroqUsageFetcher.fetchUsage(
                        apiKey: apiKey,
                        environment: context.env).toUsageSnapshot()
                }),
            cli: ProviderCLIConfig(
                name: "groqcloud",
                aliases: ["groq", "groq-api"],
                versionDetector: nil))
    }
}
