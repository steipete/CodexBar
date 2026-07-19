import Foundation

public enum BedrockProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .bedrock,
            metadata: ProviderMetadata(
                id: .bedrock,
                displayName: "AWS Bedrock",
                sessionLabel: "Budget",
                weeklyLabel: "Cost",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show AWS Bedrock usage",
                cliName: "bedrock",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://console.aws.amazon.com/bedrock",
                statusPageURL: nil,
                statusLinkURL: "https://health.aws.amazon.com/health/status"),
            branding: ProviderBranding(
                iconStyle: .bedrock,
                iconResourceName: "ProviderIcon-bedrock",
                color: ProviderColor(red: 1, green: 0.6, blue: 0),
                confettiPalette: [
                    ProviderColor(hex: 0x01A88D),
                    ProviderColor(hex: 0x232F3E),
                    ProviderColor(hex: 0xFF9900),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: { "No AWS Bedrock cost data available. Check your AWS access keys "
                    + "or profile, and that the AWS CLI is installed for profile auth."
                }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [BedrockAPIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "bedrock",
                aliases: ["aws-bedrock"],
                versionDetector: nil))
    }
}

struct BedrockAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "bedrock.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        switch BedrockSettingsReader.authMode(environment: context.env) {
        case .keys:
            BedrockSettingsReader.hasCredentials(environment: context.env)
        case .profile:
            BedrockSettingsReader.profile(environment: context.env) != nil
        }
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let resolved = try await BedrockCredentialResolver.resolve(environment: context.env)
        let budget = BedrockSettingsReader.budget(environment: context.env)
        let usage = try await BedrockUsageFetcher.fetchUsage(
            credentials: resolved.credentials,
            region: resolved.region,
            budget: budget,
            environment: context.env)
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on _: any Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
