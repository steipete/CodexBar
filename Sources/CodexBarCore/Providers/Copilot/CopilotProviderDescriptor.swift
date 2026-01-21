import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum CopilotProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .copilot,
            metadata: ProviderMetadata(
                id: .copilot,
                displayName: "Copilot",
                sessionLabel: "Premium",
                weeklyLabel: "Chat",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Copilot usage",
                cliName: "copilot",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://github.com/settings/copilot",
                statusPageURL: "https://www.githubstatus.com/"),
            branding: ProviderBranding(
                iconStyle: .copilot,
                iconResourceName: "ProviderIcon-copilot",
                color: ProviderColor(red: 168 / 255, green: 85 / 255, blue: 247 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Copilot cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [CopilotAPIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "copilot",
                versionDetector: nil))
    }
}

struct CopilotAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "copilot.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        Self.resolveToken(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let token = Self.resolveToken(environment: context.env), !token.isEmpty else {
            throw URLError(.userAuthenticationRequired)
        }
        let fetcher = CopilotUsageFetcher(token: token)
        let snap = try await fetcher.fetch()
        return self.makeResult(
            usage: snap,
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func resolveToken(environment: [String: String]) -> String? {
        ProviderTokenResolver.copilotToken(environment: environment)
    }
}
