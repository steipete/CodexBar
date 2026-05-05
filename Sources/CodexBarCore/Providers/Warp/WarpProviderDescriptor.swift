import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum WarpProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .warp,
            metadata: ProviderMetadata(
                id: .warp,
                displayName: "Warp",
                sessionLabel: "Credits",
                weeklyLabel: "Add-on credits",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Warp usage",
                cliName: "warp",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://docs.warp.dev/reference/cli/api-keys",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .warp,
                iconResourceName: "ProviderIcon-warp",
                color: ProviderColor(red: 147 / 255, green: 139 / 255, blue: 180 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Warp cost summary is not available." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [WarpAPIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "warp",
                aliases: ["warp-ai", "warp-terminal"],
                versionDetector: nil))
    }
}

struct WarpAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "warp.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        Self.resolveToken(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = Self.resolveToken(environment: context.env) else {
            throw WarpUsageError.missingCredentials
        }
        let usage = try await WarpUsageFetcher.fetchUsage(apiKey: apiKey)
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func resolveToken(environment: [String: String]) -> String? {
        ProviderTokenResolver.warpToken(environment: environment)
    }
}
