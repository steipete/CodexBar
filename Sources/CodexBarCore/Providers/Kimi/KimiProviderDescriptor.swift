import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum KimiProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .kimi,
            metadata: ProviderMetadata(
                id: .kimi,
                displayName: "Kimi Code",
                sessionLabel: "Weekly",
                weeklyLabel: "Rate Limit",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Kimi Code usage",
                cliName: "kimi",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://www.kimi.com/code/",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .kimi,
                iconResourceName: "ProviderIcon-kimi",
                color: ProviderColor(red: 254 / 255, green: 96 / 255, blue: 60 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Kimi Code cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .oauth, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "kimi",
                aliases: ["kimi-code"],
                versionDetector: nil))
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        let oauth = KimiOAuthFetchStrategy()
        let api = KimiAPIFetchStrategy()

        switch context.sourceMode {
        case .oauth:
            return [oauth]
        case .api:
            return [api]
        case .auto:
            return [oauth, api]
        case .web, .cli:
            return []
        }
    }
}

private struct KimiOAuthFetchStrategy: ProviderFetchStrategy {
    let id: String = "kimi.oauth"
    let kind: ProviderFetchKind = .oauth

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        (try? KimiOAuthCredentialsStore.load(env: context.env)) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        var credentials = try KimiOAuthCredentialsStore.load(env: context.env)
        if credentials.needsRefresh {
            credentials = try await KimiOAuthCredentialsStore.refresh(credentials, env: context.env)
        }

        let snapshot = try await KimiUsageFetcher.fetchUsage(
            apiKey: credentials.accessToken,
            environment: context.env)
        return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: "oauth")
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        guard context.sourceMode == .auto else { return false }
        return error is KimiOAuthCredentialsError || error is KimiAPIError
    }
}

private struct KimiAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "kimi.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        ProviderTokenResolver.kimiAPIKey(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = ProviderTokenResolver.kimiAPIKey(environment: context.env) else {
            throw KimiAPIError.missingToken
        }

        let snapshot = try await KimiUsageFetcher.fetchUsage(
            apiKey: apiKey,
            environment: context.env)
        return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
