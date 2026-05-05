import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum CodebuffProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .codebuff,
            metadata: ProviderMetadata(
                id: .codebuff,
                displayName: "Codebuff",
                sessionLabel: "Credits",
                weeklyLabel: "Weekly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: true,
                creditsHint: "Credit balance from the Codebuff API",
                toggleTitle: "Show Codebuff usage",
                cliName: "codebuff",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://www.codebuff.com/usage",
                statusPageURL: nil,
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .codebuff,
                iconResourceName: "ProviderIcon-codebuff",
                color: ProviderColor(red: 68 / 255, green: 255 / 255, blue: 0 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Codebuff cost summary is not yet supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [CodebuffAPIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "codebuff",
                aliases: ["manicode"],
                versionDetector: nil))
    }
}

struct CodebuffAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "codebuff.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        _ = context
        // Keep the strategy available so missing-token surfaces as a user-friendly error
        // instead of a generic "no strategy" outcome.
        return true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let resolution = Self.resolveToken(environment: context.env) else {
            throw CodebuffUsageError.missingCredentials
        }
        let usage = try await CodebuffUsageFetcher.fetchUsage(
            apiKey: resolution.token,
            environment: context.env,
            includeSubscription: Self.shouldFetchSubscription(for: resolution))
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    static func shouldFetchSubscription(for resolution: ProviderTokenResolution) -> Bool {
        resolution.source == .authFile
    }

    private static func resolveToken(environment: [String: String]) -> ProviderTokenResolution? {
        ProviderTokenResolver.codebuffResolution(environment: environment)
    }
}

/// Errors related to Codebuff settings.
public enum CodebuffSettingsError: LocalizedError, Sendable {
    case missingToken

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "Codebuff API token not configured. Set CODEBUFF_API_KEY or run `codebuff login` to " +
                "populate ~/.config/manicode/credentials.json."
        }
    }
}
