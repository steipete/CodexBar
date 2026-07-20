import Foundation

public enum ZenMuxProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .zenmux,
            metadata: ProviderMetadata(
                id: .zenmux,
                displayName: "ZenMux",
                sessionLabel: "5-hour quota",
                weeklyLabel: "Weekly quota",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show ZenMux usage",
                cliName: "zenmux",
                defaultEnabled: false,
                dashboardURL: "https://zenmux.ai/platform/management",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .zenmux,
                iconResourceName: "ProviderIcon-zenmux",
                color: ProviderColor(red: 108 / 255, green: 92 / 255, blue: 231 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x6C5CE7),
                    ProviderColor(hex: 0xA29BFE),
                    ProviderColor(hex: 0xFFFFFF),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "ZenMux cost history is not exposed by the Management API." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [ZenMuxAPIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "zenmux",
                aliases: ["zen-mux"],
                versionDetector: nil))
    }
}

struct ZenMuxAPIFetchStrategy: ProviderFetchStrategy {
    let id = "zenmux.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        ZenMuxSettingsReader.managementAPIKey(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let credential = ZenMuxSettingsReader.managementAPIKey(environment: context.env) else {
            throw ZenMuxUsageError.notConfigured
        }
        let shouldFetchCredits = context.runtime == .app
            ? context.includeOptionalUsage
            : context.includeCredits
        let result = try await ZenMuxUsageFetcher.fetchUsage(
            credential,
            includePaygBalance: shouldFetchCredits)
        return self.makeResult(
            usage: result.usage.toUsageSnapshot(paygBalanceUSD: result.paygBalanceUSD),
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
