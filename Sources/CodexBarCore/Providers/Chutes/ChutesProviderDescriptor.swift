import Foundation

public enum ChutesProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .chutes,
            metadata: ProviderMetadata(
                id: .chutes,
                displayName: "Chutes",
                sessionLabel: "4-hour quota",
                weeklyLabel: "Monthly quota",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "Subscription usage from the Chutes API.",
                toggleTitle: "Show Chutes usage",
                cliName: "chutes",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://chutes.ai",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .chutes,
                iconResourceName: "ProviderIcon-chutes",
                color: ProviderColor(red: 49 / 255, green: 132 / 255, blue: 255 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x121212),
                    ProviderColor(hex: 0xFFFFFF),
                    ProviderColor(hex: 0x63D297),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Chutes cost history is not available from CodexBar." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [ChutesAPIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "chutes",
                aliases: ["chutes.ai"],
                versionDetector: nil))
    }
}

struct ChutesAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "chutes.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        ChutesSettingsReader.apiKey(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = ChutesSettingsReader.apiKey(environment: context.env) else {
            throw ChutesSettingsError.missingToken
        }

        let usage = try await ChutesUsageFetcher.fetchUsage(
            apiKey: apiKey,
            environment: context.env)

        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
