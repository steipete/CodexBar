import Foundation

public enum AiAndProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .aiand,
            metadata: ProviderMetadata(
                id: .aiand,
                displayName: "ai&",
                sessionLabel: "Spend",
                weeklyLabel: "Spend",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show ai& usage",
                cliName: "aiand",
                defaultEnabled: false,
                dashboardURL: "https://console.aiand.com",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .aiand,
                iconResourceName: "ProviderIcon-aiand",
                color: ProviderColor(red: 226 / 255, green: 92 / 255, blue: 43 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0xE25C2B),
                    ProviderColor(hex: 0xF2A17E),
                    ProviderColor(hex: 0x33231C),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "ai& spend is summed from the request logs API." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [AiAndAPIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "aiand",
                aliases: ["ai&", "ai-and"],
                versionDetector: nil))
    }
}

struct AiAndAPIFetchStrategy: ProviderFetchStrategy {
    let id = "aiand.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        AiAndSettingsReader.apiKey(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let credential = AiAndSettingsReader.apiKey(environment: context.env) else {
            throw AiAndUsageError.notConfigured
        }
        let usage = try await AiAndUsageFetcher.fetchUsage(credential)
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
