import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum WindsurfProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .windsurf,
            metadata: ProviderMetadata(
                id: .windsurf,
                displayName: "Windsurf",
                sessionLabel: "Daily",
                weeklyLabel: "Weekly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Windsurf usage",
                cliName: "windsurf",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://windsurf.com/subscription/usage",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .windsurf,
                iconResourceName: "ProviderIcon-windsurf",
                color: ProviderColor(red: 52 / 255, green: 232 / 255, blue: 187 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Windsurf cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [WindsurfLocalFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "windsurf",
                versionDetector: nil))
    }
}

struct WindsurfLocalFetchStrategy: ProviderFetchStrategy {
    let id: String = "windsurf.local"
    let kind: ProviderFetchKind = .localProbe

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let probe = WindsurfStatusProbe()
        let planInfo = try probe.fetch()
        let usage = planInfo.toUsageSnapshot()
        return self.makeResult(
            usage: usage,
            sourceLabel: "local")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
