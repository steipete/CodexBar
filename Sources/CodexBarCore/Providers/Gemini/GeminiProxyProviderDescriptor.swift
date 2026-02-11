import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum GeminiProxyProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .geminiproxy,
            metadata: ProviderMetadata(
                id: .geminiproxy,
                displayName: "CLIProxy Gemini",
                sessionLabel: "Pro",
                weeklyLabel: "Flash",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show CLIProxy Gemini usage",
                cliName: "gemini-proxy",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "http://127.0.0.1:8317/management.html#/usage",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .gemini,
                iconResourceName: "ProviderIcon-gemini",
                color: ProviderColor(red: 171 / 255, green: 135 / 255, blue: 234 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Gemini cost summary is not supported for CLIProxy source." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [GeminiCLIProxyFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "gemini-proxy",
                aliases: ["cliproxy-gemini"],
                versionDetector: nil))
    }
}

private struct GeminiCLIProxyFetchStrategy: ProviderFetchStrategy {
    let id: String = "geminiproxy.api"
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
        let auth = try await client.resolveGeminiAuth()
        let quota = try await client.fetchGeminiQuota(auth: auth)
        let snapshot = CLIProxyGeminiQuotaSnapshotMapper.usageSnapshot(
            from: quota,
            auth: auth,
            provider: .geminiproxy)

        return self.makeResult(
            usage: snapshot,
            sourceLabel: "cliproxy-api")
    }

    func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
        context.sourceMode == .auto
    }
}
