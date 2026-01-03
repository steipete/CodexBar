import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum KiroProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .kiro,
            metadata: ProviderMetadata(
                id: .kiro,
                displayName: "Kiro",
                sessionLabel: "Credits",
                weeklyLabel: "Bonus",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Kiro usage",
                cliName: "kiro",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://app.kiro.dev/account/usage",
                statusPageURL: nil,
                statusLinkURL: "https://health.aws.amazon.com/health/status"),
            branding: ProviderBranding(
                iconStyle: .kiro,
                iconResourceName: "ProviderIcon-kiro",
                color: ProviderColor(red: 255 / 255, green: 153 / 255, blue: 0 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Kiro cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [KiroCLIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "kiro",
                aliases: ["kiro-cli"],
                versionDetector: { _ in KiroStatusProbe.detectVersion() }))
    }
}

struct KiroCLIFetchStrategy: ProviderFetchStrategy {
    let id: String = "kiro.cli"
    let kind: ProviderFetchKind = .cli

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        TTYCommandRunner.which("kiro-cli") != nil
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        let probe = KiroStatusProbe()
        let snap = try await probe.fetch()
        return self.makeResult(
            usage: snap.toUsageSnapshot(),
            sourceLabel: "cli")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
