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
                sessionLabel: "Monthly",
                weeklyLabel: "On-demand",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Grok usage",
                cliName: "grok",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://grok.com/?_s=usage",
                changelogURL: "https://x.ai/news",
                statusPageURL: nil,
                statusLinkURL: "https://status.x.ai"),
            branding: ProviderBranding(
                iconStyle: .grok,
                iconResourceName: "ProviderIcon-grok",
                color: ProviderColor(red: 16 / 255, green: 163 / 255, blue: 127 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Grok cost summary is not supported yet." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [GrokCLIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "grok",
                versionDetector: { _ in GrokStatusProbe.detectVersion() }))
    }
}

struct GrokCLIFetchStrategy: ProviderFetchStrategy {
    let id: String = "grok.cli"
    let kind: ProviderFetchKind = .cli

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        BinaryLocator.resolveGrokBinary() != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let probe = GrokStatusProbe()
        let snap = try await probe.fetch(env: context.env)
        let sourceLabel = snap.billing != nil ? "grok-cli" : "grok-local"
        return self.makeResult(
            usage: snap.toUsageSnapshot(),
            sourceLabel: sourceLabel)
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
