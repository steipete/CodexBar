import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum GrokProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .grok,
            metadata: ProviderMetadata(
                id: .grok,
                displayName: "Grok",
                sessionLabel: "Usage",
                weeklyLabel: "Balance",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: true,
                creditsHint: "Credit balance from xAI Management API",
                toggleTitle: "Show Grok usage",
                cliName: "grok",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://console.x.ai",
                statusPageURL: nil,
                statusLinkURL: "https://status.x.ai"),
            branding: ProviderBranding(
                iconStyle: .grok,
                iconResourceName: "ProviderIcon-grok",
                color: ProviderColor(red: 0 / 255, green: 0 / 255, blue: 0 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Grok cost summary is not yet supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                    [GrokManagementFetchStrategy(), GrokAPIFetchStrategy()]
                })),
            cli: ProviderCLIConfig(
                name: "grok",
                aliases: ["xai"],
                versionDetector: nil))
    }
}

// MARK: - Management API Strategy (primary: billing data)

struct GrokManagementFetchStrategy: ProviderFetchStrategy {
    let id: String = "grok.management"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        Self.resolveManagementKey(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let managementKey = Self.resolveManagementKey(environment: context.env) else {
            throw GrokSettingsError.missingManagementKey
        }
        let teamID = GrokSettingsReader.teamID(environment: context.env)
        let billing = try await GrokUsageFetcher.fetchBilling(
            managementKey: managementKey,
            teamID: teamID,
            environment: context.env)
        return self.makeResult(
            usage: billing.toUsageSnapshot(),
            sourceLabel: "management-api")
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        guard context.sourceMode == .auto else { return false }
        if error is GrokSettingsError { return true }
        if case GrokUsageError.missingManagementKey = error { return true }
        return false
    }

    private static func resolveManagementKey(environment: [String: String]) -> String? {
        GrokSettingsReader.managementKey(environment: environment)
    }
}

// MARK: - Regular API Strategy (fallback: key status)

struct GrokAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "grok.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        Self.resolveToken(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = Self.resolveToken(environment: context.env) else {
            throw GrokSettingsError.missingToken
        }
        let keyStatus = try await GrokUsageFetcher.fetchKeyStatus(
            apiKey: apiKey,
            environment: context.env)
        return self.makeResult(
            usage: keyStatus.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func resolveToken(environment: [String: String]) -> String? {
        ProviderTokenResolver.grokToken(environment: environment)
    }
}
