import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum WaferProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .wafer,
            metadata: ProviderMetadata(
                id: .wafer,
                displayName: "Wafer",
                sessionLabel: "Status",
                weeklyLabel: "Status",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Wafer status",
                cliName: "wafer",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://wafer.ai/pass",
                statusPageURL: nil,
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .wafer,
                iconResourceName: "ProviderIcon-wafer",
                color: ProviderColor(red: 0.43, green: 0.16, blue: 0.85)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Wafer cost history is not tracked via API." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [WaferAPIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "wafer",
                aliases: [],
                versionDetector: nil))
    }
}

struct WaferAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "wafer.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        Self.resolveToken(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = Self.resolveToken(environment: context.env) else {
            throw WaferUsageError.missingCredentials
        }
        let usage = try await WaferUsageFetcher.fetchUsage(apiKey: apiKey)
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func resolveToken(environment: [String: String]) -> String? {
        ProviderTokenResolver.waferToken(environment: environment)
    }
}
