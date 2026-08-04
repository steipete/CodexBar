import Foundation

public enum XAIProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .xai,
            metadata: ProviderMetadata(
                id: .xai,
                displayName: "xAI",
                sessionLabel: "Spend",
                weeklyLabel: "Spend",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show xAI usage",
                cliName: "xai",
                defaultEnabled: false,
                widgetSelectable: false,
                dashboardURL: "https://console.x.ai",
                statusPageURL: nil,
                statusLinkURL: "https://status.x.ai"),
            branding: ProviderBranding(
                iconStyle: .init(provider: .xai),
                iconResourceName: "ProviderIcon-xai",
                color: ProviderColor(red: 142 / 255, green: 142 / 255, blue: 147 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x1A1A1A),
                    ProviderColor(hex: 0x8E8E93),
                    ProviderColor(hex: 0xF5F5F7),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "xAI spend history comes from the Management API billing endpoints." }),
            fetchPlan: self.fetchPlan(),
            cli: ProviderCLIConfig(
                name: "xai",
                versionDetector: nil))
    }

    private static func fetchPlan() -> ProviderFetchPlan {
        ProviderFetchPlan(
            sourceModes: [.auto, .api],
            pipeline: ProviderFetchPipeline(resolveStrategies: { context in
                let swift = XAIAPIFetchStrategy()
                #if canImport(JavaScriptCore)
                guard ProviderPluginPrototype.isEnabled(environment: context.env) else { return [swift] }
                return [
                    ScriptFetchStrategy(
                        id: "xai.js",
                        provider: .xai,
                        bundledPlugin: "xai",
                        secretKey: XAISettingsReader.apiKeyEnvironmentKey,
                        resolveValues: { context in
                            guard let key = XAISettingsReader.apiKey(environment: context.env),
                                  let teamID = XAISettingsReader.teamID(environment: context.env)
                            else { return nil }
                            return ScriptFetchStrategy.Values(
                                settings: [XAISettingsReader.teamIDEnvironmentKey: teamID],
                                secrets: [XAISettingsReader.apiKeyEnvironmentKey: key])
                        }),
                    swift,
                ]
                #else
                return [swift]
                #endif
            }))
    }
}

struct XAIAPIFetchStrategy: ProviderFetchStrategy {
    let id = "xai.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        XAISettingsReader.apiKey(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let key = XAISettingsReader.apiKey(environment: context.env) else {
            throw XAIBillingError.notConfigured
        }
        guard let teamID = XAISettingsReader.teamID(environment: context.env) else {
            throw XAIBillingError.missingTeamID
        }
        let usage = try await XAIBillingFetcher.fetchUsage(managementKey: key, teamID: teamID)
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
