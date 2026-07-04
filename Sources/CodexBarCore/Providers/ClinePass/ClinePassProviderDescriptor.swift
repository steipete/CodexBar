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
                dashboardURL: "https://app.cline.bot/dashboard/subscription?personal=true",
                statusPageURL: nil,
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .clinepass,
                iconResourceName: "ProviderIcon-clinepass",
                color: ProviderColor(red: 87 / 255, green: 92 / 255, blue: 247 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "ClinePass cost summary is not yet supported." }),
            fetchPlan: .apiToken(
                strategyID: "clinepass.api",
                resolveToken: { ProviderTokenResolver.clinePassToken(environment: $0) },
                missingCredentialsError: { ClinePassSettingsError.missingToken },
                loadUsage: { apiKey, context in
                    try await ClinePassUsageFetcher.fetchUsage(
                        apiKey: apiKey,
                        environment: context.env).toUsageSnapshot()
                }),
            cli: ProviderCLIConfig(
                name: "clinepass",
                aliases: ["cline"],
                versionDetector: nil))
    }
}

/// Errors related to ClinePass settings.
public enum ClinePassSettingsError: LocalizedError, Sendable, Equatable {
    case missingToken
    case invalidEndpointOverride(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "ClinePass API token not configured. Set CLINE_API_KEY environment variable or configure in Settings."
        case let .invalidEndpointOverride(key):
            "ClinePass endpoint override \(key) must use HTTPS (or a loopback HTTP host)."
        }
    }
}
