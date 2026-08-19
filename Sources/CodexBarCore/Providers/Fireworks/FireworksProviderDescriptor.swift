import Foundation

public enum FireworksProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: FireworksSettingsReader.configAPIKeyEnvironmentKey,
        additionalProjections: [
            ProviderCredentialEnvironmentProjection(
                key: FireworksSettingsReader.configAccountSlugEnvironmentKey,
                value: { $0.sanitizedAccountSlug }),
        ],
        resolve: FireworksSettingsReader.apiKey)

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .fireworks,
            settingsSection: .init(FireworksProviderSettingsKey.self),
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .fireworks,
                displayName: "Fireworks",
                sessionLabel: "Spend",
                weeklyLabel: "Spend",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Fireworks usage",
                cliName: "fireworks",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                balanceOnly: false,
                dashboardURL: "https://app.fireworks.ai",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .fireworks),
                iconResourceName: "ProviderIcon-fireworks",
                color: ProviderColor(red: 242 / 255, green: 91 / 255, blue: 28 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0xE65618),
                    ProviderColor(hex: 0xFF9A3C),
                    ProviderColor(hex: 0x2B2B2E),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Fireworks spend comes from the billing summary API; cost history is not tracked." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [FireworksAPIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "fireworks",
                aliases: ["fw"],
                versionDetector: nil))
    }
}

struct FireworksAPIFetchStrategy: ProviderFetchStrategy {
    let id = "fireworks.api"
    let kind: ProviderFetchKind = .apiToken
    private let transport: any ProviderHTTPTransport

    init(transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) {
        self.transport = transport
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        FireworksSettingsReader.apiKey(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = FireworksSettingsReader.apiKey(environment: context.env) else {
            throw FireworksUsageError.missingCredentials
        }
        let usage = try await FireworksUsageFetcher.fetchUsage(
            apiKey: apiKey,
            accountSlug: FireworksSettingsReader.accountSlug(environment: context.env),
            session: self.transport)
        var diagnostic: String?
        if usage.accountSlugWasDiscovered {
            do {
                try Self.persistAccountSlug(usage.accountSlug)
            } catch {
                diagnostic = "Auto-discovered Fireworks account '\(usage.accountSlug)' but could not save it: "
                    + error.localizedDescription
            }
        }
        let sourceLabel = usage.accountSlugWasDiscovered
            ? "api · \(usage.accountSlug) (auto-discovered)"
            : "api · \(usage.accountSlug)"
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: sourceLabel,
            diagnostic: diagnostic)
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func persistAccountSlug(_ accountSlug: String) throws {
        let store = CodexBarConfigStore()
        var config = try store.load() ?? .makeDefault()
        var providerConfig = config.providerConfig(for: UsageProvider.fireworks.instanceID)
            ?? ProviderConfig(id: UsageProvider.fireworks.instanceID)
        guard providerConfig.sanitizedAccountSlug != accountSlug else { return }
        providerConfig.accountSlug = accountSlug
        config.setProviderConfig(providerConfig)
        try store.save(config)
    }
}
