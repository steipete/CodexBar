import Foundation

public enum BedrockProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter(
        usesRegion: true,
        usesSecretKey: true,
        environmentOverride: Self.applyCredentialConfig,
        tokenResolver: { kind, environment, _ in
            guard kind == .primary, let token = BedrockSettingsReader.accessKeyID(environment: environment) else {
                return nil
            }
            return ProviderTokenResolution(token: token, source: .environment)
        },
        diagnosticSummary: { account, config, environment, _ in
            var modes = account == nil ? [] : ["tokenAccount"]
            let configHasCredentials = config?.sanitizedAPIKey != nil && config?.sanitizedSecretKey != nil
            if configHasCredentials || BedrockSettingsReader.hasCredentials(environment: environment) {
                modes.append("api")
            }
            return ProviderDiagnosticAuthSummary(configured: !modes.isEmpty, modes: modes)
        })

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .bedrock,
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .bedrock,
                displayName: "AWS Bedrock",
                shortDisplayName: "Bedrock",
                sessionLabel: "Budget",
                weeklyLabel: "Cost",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show AWS Bedrock usage",
                cliName: "bedrock",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                debugLogUnavailableMessage: "Bedrock debug log not yet implemented",
                dashboardURL: "https://console.aws.amazon.com/bedrock",
                statusPageURL: nil,
                statusLinkURL: "https://health.aws.amazon.com/health/status"),
            branding: ProviderBranding(
                iconStyle: .init(provider: .bedrock),
                iconResourceName: "ProviderIcon-bedrock",
                color: ProviderColor(red: 1 / 255, green: 168 / 255, blue: 141 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x01A88D),
                    ProviderColor(hex: 0x232F3E),
                    ProviderColor(hex: 0xFF9900),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: { "No AWS Bedrock cost data available. Check your AWS access keys "
                    + "or profile, and that the AWS CLI is installed for profile auth."
                },
                menuHintLines: [.literal("AWS Cost Explorer billing can lag.")],
                supportsTokenSnapshot: true,
                primaryValue: .latestDaily),
            presentation: ProviderUsagePresentation(menuCard: ProviderMenuCardPresentation(
                supportsInlineTokenCostDashboard: true)),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [BedrockAPIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "bedrock",
                aliases: ["aws-bedrock"],
                versionDetector: nil))
    }

    private static func applyCredentialConfig(
        base: [String: String],
        config: ProviderConfig?) -> [String: String]
    {
        guard let config else { return base }
        var environment = base
        let configMode = config.sanitizedAWSAuthMode.flatMap(BedrockAuthMode.init(rawValue:))
        if let configMode {
            environment[BedrockSettingsReader.authModeKey] = configMode.rawValue
        }
        let baseMode = BedrockSettingsReader
            .cleaned(base[BedrockSettingsReader.authModeKey])
            .flatMap { BedrockAuthMode(rawValue: $0.lowercased()) }
        let mergedAccessKey = config.sanitizedAPIKey ?? BedrockSettingsReader.accessKeyID(environment: base)
        let mergedSecretKey = config.sanitizedSecretKey ?? BedrockSettingsReader.secretAccessKey(environment: base)
        let effectiveMode: BedrockAuthMode = if let configMode {
            configMode
        } else if let baseMode {
            baseMode
        } else if mergedAccessKey != nil, mergedSecretKey != nil {
            .keys
        } else {
            BedrockSettingsReader.authMode(environment: base)
        }
        switch effectiveMode {
        case .profile:
            if let profile = config.sanitizedAWSProfile {
                environment[BedrockSettingsReader.profileKey] = profile
            }
        case .keys:
            if let accessKeyID = config.sanitizedAPIKey {
                environment[BedrockSettingsReader.accessKeyIDKey] = accessKeyID
            }
            if let secretAccessKey = config.sanitizedSecretKey {
                environment[BedrockSettingsReader.secretAccessKeyKey] = secretAccessKey
            }
        }
        if let region = config.sanitizedRegion {
            environment[BedrockSettingsReader.regionKeys[0]] = region
        }
        return environment
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
