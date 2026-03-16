import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum QwenProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .qwen,
            metadata: ProviderMetadata(
                id: .qwen,
                displayName: "Qwen",
                sessionLabel: "Requests",
                weeklyLabel: "Rate limit",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Qwen usage",
                cliName: "qwen",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://bailian.console.aliyun.com/",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .qwen,
                iconResourceName: "ProviderIcon-qwen",
                color: ProviderColor(red: 106 / 255, green: 58 / 255, blue: 255 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Qwen cost summary is not available." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [QwenAPIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "qwen",
                aliases: ["tongyi", "dashscope", "lingma"],
                versionDetector: nil))
    }
}

struct QwenAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "qwen.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        Self.resolveToken(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = Self.resolveToken(environment: context.env) else {
            throw QwenUsageError.missingCredentials
        }
        let usage = try await QwenUsageFetcher.fetchUsage(apiKey: apiKey)
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func resolveToken(environment: [String: String]) -> String? {
        ProviderTokenResolver.qwenToken(environment: environment)
    }
}
