import Foundation

public enum GeminiProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .gemini,
            metadata: ProviderMetadata(
                id: .gemini,
                displayName: "Gemini",
                sessionLabel: "Pro",
                weeklyLabel: "Flash",
                opusLabel: "Flash Lite",
                supportsOpus: true,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Gemini usage",
                cliName: "gemini",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://gemini.google.com",
                changelogURL: "https://github.com/google-gemini/gemini-cli/releases",
                statusPageURL: nil,
                statusLinkURL: "https://www.google.com/appsstatus/dashboard/products/npdyhgECDJ6tB66MxXyo/history",
                statusWorkspaceProductID: "npdyhgECDJ6tB66MxXyo"),
            branding: ProviderBranding(
                iconStyle: .gemini,
                iconResourceName: "ProviderIcon-gemini",
                color: ProviderColor(red: 171 / 255, green: 135 / 255, blue: 234 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Gemini cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [GeminiStatusFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "gemini",
                versionDetector: { _ in ProviderVersionDetector.geminiVersion() }))
    }
}

struct GeminiStatusFetchStrategy: ProviderFetchStrategy {
    static let sourceLabel = "oauth-api"

    let id: String = "gemini.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        let probe = GeminiStatusProbe()
        let snap = try await probe.fetch()
        return self.makeResult(
            usage: snap.toUsageSnapshot(),
            sourceLabel: Self.sourceLabel)
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
