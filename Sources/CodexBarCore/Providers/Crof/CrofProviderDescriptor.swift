import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum CrofProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .crof,
            metadata: ProviderMetadata(
                id: .crof,
                displayName: "Crof",
                sessionLabel: "Requests",
                weeklyLabel: "Credits",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "Credit balance from the Crof usage API",
                toggleTitle: "Show Crof usage",
                cliName: "crof",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://crof.ai/dashboard",
                statusPageURL: nil,
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .crof,
                iconResourceName: "ProviderIcon-crof",
                color: ProviderColor(red: 0.18, green: 0.67, blue: 0.58)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Crof cost summary is not available via API." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [CrofAPIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "crof",
                aliases: ["crofai"],
                versionDetector: nil))
    }
}

struct CrofAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "crof.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        Self.resolveToken(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = Self.resolveToken(environment: context.env) else {
            throw CrofUsageError.missingCredentials
        }
        let usage = try await CrofUsageFetcher.fetchUsage(apiKey: apiKey)
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func resolveToken(environment: [String: String]) -> String? {
        ProviderTokenResolver.crofToken(environment: environment)
    }
}
