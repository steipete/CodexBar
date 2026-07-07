import Foundation

public enum WayfinderProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .wayfinder,
            metadata: ProviderMetadata(
                id: .wayfinder,
                displayName: "Wayfinder",
                sessionLabel: "Savings",
                weeklyLabel: "Requests",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Wayfinder usage",
                cliName: "wayfinder",
                defaultEnabled: false,
                dashboardURL: "http://127.0.0.1:8088/router",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .wayfinder,
                iconResourceName: "ProviderIcon-wayfinder",
                color: ProviderColor(red: 16 / 255, green: 163 / 255, blue: 127 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Wayfinder savings are reported by its local gateway." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [WayfinderGatewayFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "wayfinder",
                aliases: ["wayfinder-router"],
                versionDetector: nil))
    }
}

struct WayfinderGatewayFetchStrategy: ProviderFetchStrategy {
    let id = "wayfinder.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        // The gateway's read-only endpoints are unauthenticated; the provider is
        // opt-in (defaultEnabled: false), so no credential gates availability.
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        try WayfinderSettingsReader.validateEndpointOverride(environment: context.env)
        let usage = try await WayfinderUsageFetcher.fetchUsage(
            baseURL: WayfinderSettingsReader.baseURL(environment: context.env))
        return self.makeResult(usage: usage.toUsageSnapshot(), sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
