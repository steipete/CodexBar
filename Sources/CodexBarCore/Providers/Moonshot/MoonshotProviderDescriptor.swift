import Foundation

public enum MoonshotProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .moonshot,
            metadata: ProviderMetadata(
                id: .moonshot,
                displayName: "Moonshot / Kimi Open Platform",
                shortDisplayName: "Moonshot",
                sessionLabel: "Balance",
                weeklyLabel: "Balance",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Moonshot / Kimi Open Platform balance",
                cliName: "moonshot",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://platform.moonshot.ai/console/account",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .kimi),
                iconResourceName: "ProviderIcon-kimi",
                color: ProviderColor(red: 32 / 255, green: 93 / 255, blue: 235 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x121212),
                    ProviderColor(hex: 0x305140),
                    ProviderColor(hex: 0x9F9F9F),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Moonshot / Kimi Open Platform cost summary is not available." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [MoonshotAPIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "moonshot",
                aliases: [],
                versionDetector: nil))
    }
}

struct MoonshotAPIFetchStrategy: ProviderFetchStrategy {
    let id = "moonshot.api"
    let kind: ProviderFetchKind = .apiToken
    private let transport: any ProviderHTTPTransport

    init(transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) {
        self.transport = transport
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        MoonshotSettingsReader.apiKey(for: self.region(context), environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let region = self.region(context)
        guard let apiKey = MoonshotSettingsReader.apiKey(for: region, environment: context.env) else {
            throw MoonshotUsageError.missingCredentials
        }
        let usage = try await MoonshotUsageFetcher.fetchUsage(
            apiKey: apiKey,
            region: region,
            session: self.transport)
        return self.makeResult(usage: usage.toUsageSnapshot(), sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private func region(_ context: ProviderFetchContext) -> MoonshotRegion {
        context.settings?.moonshot?.region ?? MoonshotSettingsReader.region(environment: context.env)
    }
}
