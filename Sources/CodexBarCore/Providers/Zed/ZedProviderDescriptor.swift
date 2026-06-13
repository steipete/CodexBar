import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum ZedProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .zed,
            metadata: ProviderMetadata(
                id: .zed,
                displayName: "Zed",
                sessionLabel: "Edit predictions",
                weeklyLabel: "Billing cycle",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Zed usage",
                cliName: "zed",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://dashboard.zed.dev",
                subscriptionDashboardURL: "https://dashboard.zed.dev",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .zed,
                iconResourceName: "ProviderIcon-zed",
                color: ProviderColor(red: 8 / 255, green: 78 / 255, blue: 255 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Zed cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                    [ZedLocalFetchStrategy()]
                })),
            cli: ProviderCLIConfig(
                name: "zed",
                versionDetector: nil))
    }
}

struct ZedLocalFetchStrategy: ProviderFetchStrategy {
    let id: String = "zed.local"
    let kind: ProviderFetchKind = .localProbe

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        let probe = ZedStatusProbe()
        let snapshot = try await probe.fetch()
        return self.makeResult(
            usage: snapshot.toUsageSnapshot(),
            sourceLabel: "local")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
