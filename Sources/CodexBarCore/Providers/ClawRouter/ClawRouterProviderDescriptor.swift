import Foundation

public enum ClawRouterProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .clawrouter,
            metadata: ProviderMetadata(
                id: .clawrouter,
                displayName: "ClawRouter",
                sessionLabel: "Monthly budget",
                weeklyLabel: "Requests",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show ClawRouter usage",
                cliName: "clawrouter",
                defaultEnabled: false,
                dashboardURL: "https://clawrouter.openclaw.ai/dashboard/access",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .clawrouter,
                iconResourceName: "ProviderIcon-clawrouter",
                color: ProviderColor(red: 89 / 255, green: 110 / 255, blue: 246 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x332CB3),
                    ProviderColor(hex: 0x456FDD),
                    ProviderColor(hex: 0xFFFFFF),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "ClawRouter spend is reported by its usage API." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [ClawRouterAPIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "clawrouter",
                aliases: ["claw-router"],
                versionDetector: nil))
    }
}

struct ClawRouterAPIFetchStrategy: ProviderFetchStrategy {
    let id = "clawrouter.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        ProviderTokenResolver.clawRouterToken(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = ProviderTokenResolver.clawRouterToken(environment: context.env) else {
            throw ClawRouterUsageError.missingCredentials
        }
        try ClawRouterSettingsReader.validateEndpointOverride(environment: context.env)
        let usage = try await ClawRouterUsageFetcher.fetchUsage(
            apiKey: apiKey,
            baseURL: ClawRouterSettingsReader.baseURL(environment: context.env))
        return self.makeResult(usage: usage.toUsageSnapshot(), sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
