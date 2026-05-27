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
                color: ProviderColor(red: 1, green: 0.6, blue: 0)),
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
        let credentials: BedrockAWSSigner.Credentials
        let region: String

        switch BedrockSettingsReader.authMode(environment: context.env) {
        case .keys:
            guard let accessKeyID = BedrockSettingsReader.accessKeyID(environment: context.env),
                  let secretAccessKey = BedrockSettingsReader.secretAccessKey(environment: context.env)
            else {
                throw BedrockUsageError.missingCredentials
            }
            credentials = BedrockAWSSigner.Credentials(
                accessKeyID: accessKeyID,
                secretAccessKey: secretAccessKey,
                sessionToken: BedrockSettingsReader.sessionToken(environment: context.env))
            region = BedrockSettingsReader.region(environment: context.env)

        case .profile:
            guard let profile = BedrockSettingsReader.profile(environment: context.env) else {
                throw BedrockUsageError.missingCredentials
            }
            guard let awsBinary = BinaryLocator.resolveAWSBinary(env: context.env) else {
                throw BedrockUsageError.awsCLINotFound
            }
            let resolver = BedrockProfileCredentialProvider.live(awsBinaryPath: awsBinary)
            credentials = try await resolver.exportCredentials(profile: profile, environment: context.env)
            if let explicit = BedrockSettingsReader.cleaned(context.env[BedrockSettingsReader.regionKeys[0]])
                ?? BedrockSettingsReader.cleaned(context.env[BedrockSettingsReader.regionKeys[1]])
            {
                region = explicit
            } else if let derived = try await resolver.resolveRegion(profile: profile, environment: context.env) {
                region = derived
            } else {
                region = BedrockSettingsReader.defaultRegion
            }
        }

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

    func shouldFallback(on _: any Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
