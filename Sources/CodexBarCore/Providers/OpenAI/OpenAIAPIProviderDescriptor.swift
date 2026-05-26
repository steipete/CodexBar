import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum OpenAIAPIProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .openai,
            metadata: ProviderMetadata(
                id: .openai,
                displayName: "OpenAI",
                sessionLabel: "Spend",
                weeklyLabel: "Requests",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show OpenAI usage",
                cliName: "openai",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://platform.openai.com/usage",
                statusPageURL: "https://status.openai.com"),
            branding: ProviderBranding(
                iconStyle: .openai,
                iconResourceName: "ProviderIcon-codex",
                color: ProviderColor(red: 0.06, green: 0.51, blue: 0.43)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: { "OpenAI usage needs an Admin API key for organization usage." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [OpenAIAPIBalanceFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "openai",
                aliases: ["openai-api"],
                versionDetector: nil))
    }
}

struct OpenAIAPIBalanceFetchStrategy: ProviderFetchStrategy {
    let id: String = "openai.api.balance"
    let kind: ProviderFetchKind = .apiToken
    let usageFetcher: @Sendable (String, Int) async throws -> OpenAIAPIUsageSnapshot
    let balanceFetcher: @Sendable (String) async throws -> OpenAIAPICreditBalanceSnapshot

    init(
        usageFetcher: @escaping @Sendable (String, Int) async throws -> OpenAIAPIUsageSnapshot = { apiKey, days in
            try await OpenAIAPIUsageFetcher.fetchUsage(apiKey: apiKey, historyDays: days)
        },
        balanceFetcher: @escaping @Sendable (String) async throws -> OpenAIAPICreditBalanceSnapshot = { apiKey in
            try await OpenAIAPICreditBalanceFetcher.fetchBalance(apiKey: apiKey)
        })
    {
        self.usageFetcher = usageFetcher
        self.balanceFetcher = balanceFetcher
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        Self.resolveToken(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = Self.resolveToken(environment: context.env) else {
            throw OpenAIAPISettingsError.missingToken
        }

        do {
            let usage = try await self.usageFetcher(apiKey, context.costUsageHistoryDays)
            return self.makeResult(
                usage: usage.toUsageSnapshot(),
                sourceLabel: "admin-api")
        } catch {
            let usageError = error
            // Preserve the older balance-only path for project/user keys and admin API outages.
            do {
                let balance = try await self.balanceFetcher(apiKey)
                return self.makeResult(
                    usage: balance.toUsageSnapshot(),
                    sourceLabel: "billing-api")
            } catch {
                if (usageError as? OpenAIAPIUsageError)?.isCredentialRejected != true {
                    throw usageError
                }
                throw error
            }
        }
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func resolveToken(environment: [String: String]) -> String? {
        ProviderTokenResolver.openAIAPIToken(environment: environment)
    }
}
