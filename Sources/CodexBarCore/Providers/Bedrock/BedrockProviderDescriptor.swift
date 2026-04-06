import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum BedrockProviderDescriptor {
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
                color: ProviderColor(red: 255 / 255, green: 153 / 255, blue: 0 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: { "No AWS Bedrock cost data available. Check your AWS credentials." }),
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
        BedrockSettingsReader.hasCredentials(environment: context.env)
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let accessKeyID = BedrockSettingsReader.accessKeyID(environment: context.env),
              let secretAccessKey = BedrockSettingsReader.secretAccessKey(environment: context.env)
        else {
            throw BedrockUsageError.missingCredentials
        }

        let credentials = BedrockAWSSigner.Credentials(
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey,
            sessionToken: BedrockSettingsReader.sessionToken(environment: context.env))
        let region = BedrockSettingsReader.region(environment: context.env)
        let budget = BedrockSettingsReader.budget(environment: context.env)

        let usage = try await BedrockUsageFetcher.fetchUsage(
            credentials: credentials,
            region: region,
            budget: budget,
            environment: context.env)
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
