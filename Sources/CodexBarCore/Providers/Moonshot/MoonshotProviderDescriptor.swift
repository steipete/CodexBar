import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum MoonshotProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .moonshot,
            metadata: ProviderMetadata(
                id: .moonshot,
                displayName: "Moonshot",
                sessionLabel: "Balance",
                weeklyLabel: "Balance",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Moonshot usage",
                cliName: "moonshot",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://platform.moonshot.ai/console/info",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .moonshot,
                iconResourceName: "ProviderIcon-moonshot",
                color: ProviderColor(red: 32 / 255, green: 93 / 255, blue: 235 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Moonshot cost summary is not available." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [MoonshotAPIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "moonshot",
                aliases: [],
                versionDetector: nil))
    }
}

struct MoonshotAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "moonshot.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        Self.resolveToken(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = Self.resolveToken(environment: context.env) else {
            throw MoonshotUsageError.missingCredentials
        }
        let region = context.settings?.moonshot?.region ?? MoonshotSettingsReader.region(environment: context.env)
        let usage = try await MoonshotUsageFetcher.fetchUsage(apiKey: apiKey, region: region)
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func resolveToken(environment: [String: String]) -> String? {
        ProviderTokenResolver.moonshotToken(environment: environment)
    }
}
