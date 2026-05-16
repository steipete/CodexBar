import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum ElevenLabsProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .elevenlabs,
            metadata: ProviderMetadata(
                id: .elevenlabs,
                displayName: "ElevenLabs",
                sessionLabel: "Credits",
                weeklyLabel: "Voices",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show ElevenLabs usage",
                cliName: "elevenlabs",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://elevenlabs.io/app/developers/usage",
                subscriptionDashboardURL: "https://elevenlabs.io/app/subscription",
                statusPageURL: nil,
                statusLinkURL: "https://status.elevenlabs.io"),
            branding: ProviderBranding(
                iconStyle: .elevenlabs,
                iconResourceName: "ProviderIcon-elevenlabs",
                color: ProviderColor(red: 0.92, green: 0.92, blue: 0.90)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "ElevenLabs cost history is not available via API yet." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [ElevenLabsAPIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "elevenlabs",
                aliases: ["11labs", "eleven"],
                versionDetector: nil))
    }
}

struct ElevenLabsAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "elevenlabs.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        Self.resolveToken(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = Self.resolveToken(environment: context.env) else {
            throw ElevenLabsUsageError.missingCredentials
        }
        let usage = try await ElevenLabsUsageFetcher.fetchUsage(
            apiKey: apiKey,
            environment: context.env)
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func resolveToken(environment: [String: String]) -> String? {
        ProviderTokenResolver.elevenLabsToken(environment: environment)
    }
}
