import Foundation

public enum PoeProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: PoeSettingsReader.apiKeyEnvironmentKey,
        resolve: PoeSettingsReader.apiKey)

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .poe,
            credentials: self.credentials,
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
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                balanceOnly: true,
                browserCookieOrder: nil,
                dashboardURL: "https://poe.com/api/keys",
                statusPageURL: nil,
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .poe),
                iconResourceName: "ProviderIcon-poe",
                color: ProviderColor(red: 93 / 255, green: 92 / 255, blue: 222 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x5D5CDE),
                    ProviderColor(hex: 0x2A2AA2),
                    ProviderColor(hex: 0xE051ED),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Poe usage history is unavailable." }),
            presentation: ProviderUsagePresentation(
                menuCard: ProviderMenuCardPresentation(primaryDetailKind: .poeBalance),
                planRow: ProviderPlanRowPresentation(label: "Balance", stripsBalancePrefix: true)),
            fetchPlan: self.fetchPlan(),
            cli: ProviderCLIConfig(
                name: "poe",
                aliases: [],
                versionDetector: nil))
    }

    private static func fetchPlan() -> ProviderFetchPlan {
        .scriptPrototypeAPI(
            configuration: .init(
                provider: .poe,
                plugin: "poe",
                secretKey: PoeSettingsReader.apiKeyEnvironmentKey,
                strategyID: "poe.api"),
            resolveToken: { ProviderTokenResolver.token(for: .poe, environment: $0) },
            missingCredentialsError: { PoeUsageError.missingCredentials },
            loadUsage: { apiKey, _ in
                try await PoeUsageFetcher.fetchUsage(apiKey: apiKey).toUsageSnapshot()
            })
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
        ProviderTokenResolver.token(for: .poe, environment: environment)
    }
}
