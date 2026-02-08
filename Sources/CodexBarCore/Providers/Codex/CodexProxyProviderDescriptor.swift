import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum CodexProxyProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .codexproxy,
            metadata: ProviderMetadata(
                id: .codexproxy,
                displayName: "CLIProxy Codex",
                sessionLabel: L10n.tr("provider.codex.metadata.session_label", fallback: "Session"),
                weeklyLabel: L10n.tr("provider.codex.metadata.weekly_label", fallback: "Weekly"),
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show CLIProxy Codex usage",
                cliName: "codex-proxy",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "http://127.0.0.1:8317/management.html#/usage",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .codex,
                iconResourceName: "ProviderIcon-codex",
                color: ProviderColor(red: 73 / 255, green: 163 / 255, blue: 176 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: { "No Codex sessions found in local logs for CLIProxy Codex." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [CodexProxyCLIProxyFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "codex-proxy",
                aliases: ["cliproxy-codex"],
                versionDetector: nil))
    }
}

private struct CodexProxyCLIProxyFetchStrategy: ProviderFetchStrategy {
    let id: String = "codexproxy.api"
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
        let auth = try await client.resolveCodexAuth()
        let usage = try await client.fetchCodexUsage(auth: auth)
        let snapshot = CodexUsageSnapshotMapper.usageSnapshot(
            from: usage,
            accountEmail: auth.email,
            fallbackLoginMethod: auth.planType)
            .scoped(to: .codexproxy)

        return self.makeResult(
            usage: snapshot,
            sourceLabel: "cliproxy-api")
    }

    func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
        context.sourceMode == .auto
    }
}
