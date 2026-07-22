import Foundation

public enum KiroProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

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
                // Kiro's brand orange (#FF9900) reads visually identical to Claude's
                // terracotta (#CC7C5E) at Touch Bar scale — use the same purple this
                // user's other tools (Kouen-Terminal's AgentKind.kiro.dotHex) already
                // use to identify Kiro, for cross-tool consistency.
                color: ProviderColor(hex: 0x8B5CF6),
                confettiPalette: [
                    ProviderColor(hex: 0x8F4AFF),
                    ProviderColor(hex: 0xCAA9FF),
                    ProviderColor(hex: 0x2B2B2B),
                ]),
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
