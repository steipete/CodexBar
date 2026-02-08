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
                sessionLabel: "Messages",
                weeklyLabel: "Credits",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Windsurf usage",
                cliName: "windsurf",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: nil,
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .windsurf,
                iconResourceName: "ProviderIcon-windsurf",
                color: ProviderColor(red: 14 / 255, green: 165 / 255, blue: 166 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Windsurf cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [WindsurfLocalStorageFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "windsurf",
                aliases: ["ws"],
                versionDetector: nil))
    }
}

struct WindsurfLocalStorageFetchStrategy: ProviderFetchStrategy {
    let id: String = "windsurf.local"
    let kind: ProviderFetchKind = .localProbe

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let info = try WindsurfLocalStorageReader.loadCachedPlanInfo(environment: context.env)
        let usage = try WindsurfLocalStorageReader.makeUsageSnapshot(info: info)
        return self.makeResult(
            usage: usage,
            sourceLabel: "local")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
