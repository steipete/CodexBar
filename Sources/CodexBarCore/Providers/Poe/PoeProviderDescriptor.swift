import Foundation

public enum PoeProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .poe,
            metadata: ProviderMetadata(
                id: .poe,
                displayName: "Poe",
                sessionLabel: "Points",
                weeklyLabel: "Points",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Poe usage",
                cliName: "poe",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://poe.com/api/keys",
                statusPageURL: nil,
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .poe,
                iconResourceName: "ProviderIcon-poe",
                color: ProviderColor(red: 93 / 255, green: 92 / 255, blue: 222 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Poe usage history is unavailable." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [PoeAPIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "poe",
                aliases: [],
                versionDetector: nil))
    }
}

struct PoeAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "poe.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        Self.resolveToken(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = Self.resolveToken(environment: context.env) else {
            throw PoeUsageError.missingCredentials
        }
        let usage = try await PoeUsageFetcher.fetchUsage(apiKey: apiKey)
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func resolveToken(environment: [String: String]) -> String? {
        ProviderTokenResolver.poeToken(environment: environment)
    }
}
