import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum AntigravityProxyProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .antigravityproxy,
            metadata: ProviderMetadata(
                id: .antigravityproxy,
                displayName: "CLIProxy Antigravity",
                sessionLabel: "Pro",
                weeklyLabel: "Flash",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show CLIProxy Antigravity usage",
                cliName: "antigravity-proxy",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "http://127.0.0.1:8317/management.html#/usage",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .antigravity,
                iconResourceName: "ProviderIcon-antigravity",
                color: ProviderColor(red: 96 / 255, green: 186 / 255, blue: 126 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Antigravity cost summary is not supported for CLIProxy source." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [AntigravityCLIProxyFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "antigravity-proxy",
                aliases: ["cliproxy-antigravity"],
                versionDetector: nil))
    }
}

private struct AntigravityCLIProxyFetchStrategy: ProviderFetchStrategy {
    let id: String = "antigravityproxy.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        CodexCLIProxySettings.resolve(
            providerSettings: context.settings?.codex,
            environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let settings = CodexCLIProxySettings.resolve(
            providerSettings: context.settings?.codex,
            environment: context.env)
        else {
            throw CodexCLIProxyError.missingManagementKey
        }

        let client = CodexCLIProxyManagementClient(settings: settings)
        let auth = try await client.resolveAntigravityAuth()
        let quota = try await client.fetchAntigravityQuota(auth: auth)
        let snapshot = CLIProxyGeminiQuotaSnapshotMapper.usageSnapshot(
            from: quota,
            auth: auth,
            provider: .antigravityproxy)

        return self.makeResult(
            usage: snapshot,
            sourceLabel: "cliproxy-api")
    }

    func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
        context.sourceMode == .auto
    }
}
