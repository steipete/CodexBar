import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum JetBrainsProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .jetbrains,
            metadata: ProviderMetadata(
                id: .jetbrains,
                displayName: "JetBrains AI",
                sessionLabel: "Current",
                weeklyLabel: "Refill",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show JetBrains AI usage",
                cliName: "jetbrains",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: nil,
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .jetbrains,
                iconResourceName: "ProviderIcon-jetbrains",
                color: ProviderColor(red: 255 / 255, green: 51 / 255, blue: 153 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "JetBrains AI cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [JetBrainsStatusFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "jetbrains",
                versionDetector: nil))
    }
}

struct JetBrainsStatusFetchStrategy: ProviderFetchStrategy {
    let id: String = "jetbrains.local"
    let kind: ProviderFetchKind = .localProbe

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let probe = JetBrainsStatusProbe(settings: context.settings)
        let snap = try await probe.fetch()
        let usage = try snap.toUsageSnapshot()
        return self.makeResult(
            usage: usage,
            sourceLabel: "local")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
